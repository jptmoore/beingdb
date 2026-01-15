(** API: Dream-based REST API for querying the Pack backend
    
    Endpoints:
    - GET /predicates - List all predicates
    - GET /query/:predicate - Get all facts for a predicate
    - POST /query - Execute queries with pattern matching and joins
    - POST /sync - Trigger Git → Pack sync (authorized only)
    
    All reads go to Pack (fast).
    All writes go through Git commits (external).
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
  `List (List.map (fun s -> `String s) args)

(** List all predicates *)
let handle_list_predicates pack_store _req =
  Pack_backend.list_predicates pack_store
  >>= fun predicates ->
  let json = `Assoc [
    "predicates", `List (List.map (fun p -> `String p) predicates)
  ] in
  json_response json

(** Get all facts for a predicate *)
let handle_query pack_store predicate _req =
  Pack_backend.query_all pack_store predicate
  >>= fun results ->
  let json = `Assoc [
    "predicate", `String predicate;
    "facts", `List (List.map fact_to_json results)
  ] in
  json_response json

(** Trigger sync (should be authorized in production) *)
let handle_sync git_store pack_store _req =
  Sync.sync git_store pack_store
  >>= fun () ->
  json_response (`Assoc ["status", `String "sync completed"])

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
              | None -> error_response "Invalid query syntax"
              | Some query ->
                  (* Enforce max results limit as ceiling to prevent OOM *)
                  let is_join = List.length query.patterns > 1 in
                  let limit_to_use = 
                    match limit with
                    | Some user_limit -> Some (min user_limit max_results)
                    | None -> Some max_results
                  in
                  
                  (* Use streaming for joins with pagination *)
                  let use_streaming = 
                    is_join && 
                    Option.is_some offset && 
                    Option.is_some limit_to_use
                  in
                  
                  if use_streaming then
                    (* Two-pass streaming approach for large joins:
                       Pass 1: Stream through join counting results (no materialization)
                       Pass 2: Stream to collect just the requested page *)
                    let offset_val = Option.value offset ~default:0 in
                    let limit_val = Option.get limit_to_use in
                    
                    (* Pass 1: Count total by streaming (constant memory) *)
                    Query_engine.count_streaming pack_store query
                    >>= fun total ->
                    
                    (* Pass 2: Stream to get the page (early cutoff) *)
                    Query_engine.execute_streaming pack_store query ~offset:offset_val ~limit:limit_val
                    >>= fun page_result ->
                    
                    (* Build response with total from count pass *)
                    let json = Query_engine.result_to_json ~offset:offset_val ~limit:limit_val page_result in
                    let open Yojson.Safe.Util in
                    let json_obj = to_assoc json in
                    let json_with_total = `Assoc (("total", `Int total) :: (List.remove_assoc "total" json_obj)) in
                    json_response json_with_total
                  else
                    (* Single predicate or unpaginated: full materialization is fine *)
                    Query_engine.execute pack_store query
                    >>= fun result ->
                    json_response (Query_engine.result_to_json ?offset ?limit:limit_to_use result))
          | _ -> error_response "Missing 'query' field")
      | _ -> error_response "Expected JSON object"

(** Build Dream router *)
let router max_results git_store pack_store =
  Dream.router [
    Dream.get "/" handle_root;
    
    Dream.get "/version" handle_version;
    
    Dream.get "/predicates" 
      (handle_list_predicates pack_store);
    
    Dream.get "/query/:predicate" 
      (fun req ->
        let predicate = Dream.param req "predicate" in
        handle_query pack_store predicate req);
    
    Dream.post "/query"
      (handle_query_language max_results pack_store);
    
    Dream.post "/sync"
      (handle_sync git_store pack_store);
  ]

(** Start the API server *)
let serve ~max_results ~port ~git_store ~pack_store =
  Logs.info (fun m -> m "Starting API server on port %d" port);
  Dream.run ~port
    (Dream.logger
    @@ router max_results git_store pack_store)

(** Pack-only server (no Git backend, no sync endpoint) *)
let serve_pack_only max_results pack_store port =
  let router = Dream.router [
    Dream.get "/" handle_root;
    
    Dream.get "/version" handle_version;
    
    Dream.get "/predicates" 
      (handle_list_predicates pack_store);
    
    Dream.get "/query/:predicate" 
      (fun req ->
        let predicate = Dream.param req "predicate" in
        handle_query pack_store predicate req);
    
    Dream.post "/query"
      (handle_query_language max_results pack_store);
  ] in
  
  Dream.run ~port (Dream.logger @@ router)
