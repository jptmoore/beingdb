(** API: Dream-based REST API for querying the Pack backend
    
    Endpoints:
    - GET /predicates - List all predicates
    - GET /query/:predicate - Get all facts for a predicate
    - POST /query - Execute queries with pattern matching and joins
    
    All reads go to Pack (fast).
    Updates are done via recompile + redeploy workflow.
*)

open Lwt.Infix

let json_response data =
  Dream.json (Yojson.Safe.to_string data)

let error_response msg =
  Dream.json ~status:`Bad_Request 
    (Yojson.Safe.to_string (`Assoc ["error", `String msg]))

(** Health check endpoint *)
let handle_root _req =
  Dream.respond "OK"

(** Version endpoint *)
let handle_version _req =
  let json = `Assoc [
    "version", `String Version.version;
    "name", `String "BeingDB"
  ] in
  json_response json

(** Convert fact arguments to JSON *)
let fact_to_json args =
  `List (List.map (fun arg -> `String (Types.arg_to_string arg)) args)

(** List all predicates *)
let handle_list_predicates pack_store req =
  (* Check for samples query parameter *)
  let samples = 
    match Dream.query req "samples" with
    | None -> None
    | Some s -> 
        match int_of_string_opt s with
        | Some n when n > 0 && n <= 100 -> Some n  (* Cap at 100 samples per predicate *)
        | _ -> None
  in
  
  match samples with
  | None ->
      (* No samples - just return predicates with arity *)
      Pack_backend.list_predicates_with_arity pack_store
      >>= fun predicates_with_arity ->
      let predicates_json = List.map (fun (name, arity) ->
        `Assoc [
          "name", `String name;
          "arity", `Int arity
        ]
      ) predicates_with_arity in
      let json = `Assoc [
        "predicates", `List predicates_json
      ] in
      json_response json
  | Some limit ->
      (* Samples requested - return predicates with arity and sample facts *)
      Pack_backend.list_predicates_with_arity_and_samples ~samples:limit pack_store
      >>= fun predicates_with_samples ->
      
      let predicates_json = List.map (fun (name, arity, samples_opt) ->
        let base = [
          "name", `String name;
          "arity", `Int arity
        ] in
        match samples_opt with
        | None -> `Assoc base
        | Some sample_facts ->
            `Assoc (base @ [
              "samples", `List (List.map fact_to_json sample_facts);
              "sample_count", `Int (List.length sample_facts)
            ])
      ) predicates_with_samples in
      let json = `Assoc [
        "predicates", `List predicates_json;
        "samples_per_predicate", `Int limit
      ] in
      json_response json

(** Get all facts for a predicate with result limits *)
let handle_query max_results pack_store predicate _req =
  (* Validate predicate name to prevent injection attacks *)
  match Query_safety.validate_predicate_name predicate with
  | Error err -> error_response (Query_safety.error_message err)
  | Ok () ->
      (* Apply limit to prevent OOM on large predicates *)
      Pack_backend.query_all_limited ~limit:max_results pack_store predicate
      >>= fun results ->
      let json = `Assoc [
        "predicate", `String predicate;
        "facts", `List (List.map fact_to_json results);
        "count", `Int (List.length results);
        "limited", `Bool true;
        "max_results", `Int max_results
      ] in
      json_response json

(** Execute query with timeout wrapper - extracted to avoid duplication *)
let execute_query_with_protection pack_store query offset limit_to_use =
  let is_join = List.length query.Query_parser.patterns > 1 in
  let use_streaming = 
    is_join && 
    Option.is_some limit_to_use
  in
  
  Lwt.catch
    (fun () ->
      Lwt_unix.with_timeout Query_safety.Config.query_timeout (fun () ->
        if use_streaming then
          let offset_val = Option.value offset ~default:0 in
          let limit_val = Option.get limit_to_use in
          
          (* Skip expensive count, just stream the page *)
          Query_engine.execute_streaming pack_store query ~offset:offset_val ~limit:limit_val
          >>= fun page_result ->
          
          (* Build response without total count *)
          let result_json = `Assoc [
            "results", `List (List.map (fun binding ->
              `Assoc [
                "bindings", `List (List.map (fun (var, value) ->
                  `Assoc ["variable", `String var; "value", `String value]
                ) binding)
              ]
            ) page_result.Query_engine.bindings);
            "variables", `List (List.map (fun v -> `String v) page_result.Query_engine.variables);
          ] in
          json_response result_json
        else
          (* Single predicate or unpaginated: full materialization is fine *)
          Query_engine.execute pack_store query
          >>= fun result ->
          json_response (Query_engine.result_to_json ?offset ?limit:limit_to_use result)
      )
    )
    (function
      | Lwt_unix.Timeout ->
          error_response (Printf.sprintf "Query timeout after %.0f seconds - query too expensive. Try limiting predicates or adding more specific constraints." Query_safety.Config.query_timeout)
      | exn ->
          error_response (Printf.sprintf "Query error: %s" (Printexc.to_string exn))
    )

(** Execute a query with joins *)
let handle_query_language max_results pack_store req =
  Dream.body req
  >>= fun body ->
  
  (* Parse JSON request *)
  match Yojson.Safe.from_string body with
  | exception _ -> error_response "Invalid JSON"
  | json ->
      match json with
      | `Assoc fields ->
          (match List.assoc_opt "query" fields with
          | Some (`String query_str) ->
              (* Extract optional offset and limit *)
              let offset = 
                match List.assoc_opt "offset" fields with
                | Some (`Int n) -> Some n
                | _ -> None
              in
              let limit = 
                match List.assoc_opt "limit" fields with
                | Some (`Int n) -> Some n
                | _ -> None
              in
              
              (* Parse query *)
              (match Query_parser.parse_query query_str with
              | None -> error_response (Query_safety.error_message Query_safety.InvalidSyntax)
              | Some query ->
                  (* Validate query structure and parameters *)
                  (match Query_safety.validate_query query offset limit with
                  | Error err -> error_response (Query_safety.error_message err)
                  | Ok (valid_offset, valid_limit) ->
                      (* Enforce max results limit as ceiling to prevent OOM *)
                      let limit_to_use = 
                        match valid_limit with
                        | Some user_limit -> Some (min user_limit max_results)
                        | None -> Some max_results
                      in
                      
                      (* Execute query with timeout and result limits *)
                      execute_query_with_protection pack_store query valid_offset limit_to_use
                  ))
          | _ -> error_response "Missing 'query' field")
      | _ -> error_response "Expected JSON object"

(** Start the API server *)
let serve max_results pack_store port =
  let router = Dream.router [
    Dream.get "/" handle_root;
    
    Dream.get "/version" handle_version;
    
    Dream.get "/predicates" (handle_list_predicates pack_store);
    
    Dream.get "/query/:predicate" (fun req ->
      let predicate = Dream.param req "predicate" in
      handle_query max_results pack_store predicate req);
    
    Dream.post "/query" (handle_query_language max_results pack_store);
  ] in
  
  Dream.run ~interface:"0.0.0.0" ~port (Dream.logger @@ router)
