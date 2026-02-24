(** Controller: Business logic layer for query execution and validation *)

open Lwt.Infix

(** Convert fact arguments to JSON *)
let fact_to_json args =
  `List (List.map (fun arg -> `String (Types.arg_to_string arg)) args)

(** Convert query result to JSON *)
let query_result_to_json ?offset ?limit result =
  let total_count = result.Model.total_count in
  
  (* Apply pagination *)
  let offset_val = Option.value offset ~default:0 in
  let limit_val = Option.value limit ~default:total_count in
  
  let paginated_bindings = 
    result.Model.bindings
    |> (fun l -> List.filteri (fun i _ -> i >= offset_val) l)
    |> (fun l -> List.filteri (fun i _ -> i < limit_val) l)
  in
  
  let bindings_json = List.map (fun binding ->
    let pairs = List.map (fun (var, value) ->
      (var, `String value)
    ) binding in
    `Assoc pairs
  ) paginated_bindings in
  
  let response = [
    "variables", `List (List.map (fun v -> `String v) result.Model.variables);
    "results", `List bindings_json;
    "count", `Int (List.length paginated_bindings);
    "total", `Int total_count;
  ] in
  
  let response = match offset with
    | Some o -> response @ ["offset", `Int o]
    | None -> response
  in
  let response = match limit with
    | Some l -> response @ ["limit", `Int l]
    | None -> response
  in
  
  `Assoc response

(** List predicates with optional samples *)
let list_predicates ~samples store =
  match samples with
  | None ->
      Model.list_predicates store
      >>= fun predicates ->
      let predicates_json = List.map (fun pred ->
        `Assoc [
          "name", `String pred.Model.name;
          "arity", `Int pred.Model.arity
        ]
      ) predicates in
      let json = `Assoc [
        "predicates", `List predicates_json
      ] in
      Lwt.return (Ok json)
  | Some limit ->
      Model.list_predicates_with_samples ~samples:limit store
      >>= fun predicates ->
      let predicates_json = List.map (fun pred ->
        let base = [
          "name", `String pred.Model.name;
          "arity", `Int pred.Model.arity
        ] in
        match pred.Model.sample_facts with
        | None -> `Assoc base
        | Some sample_facts ->
            `Assoc (base @ [
              "samples", `List (List.map fact_to_json sample_facts);
              "sample_count", `Int (List.length sample_facts)
            ])
      ) predicates in
      let json = `Assoc [
        "predicates", `List predicates_json;
        "samples_per_predicate", `Int limit
      ] in
      Lwt.return (Ok json)

(** Query single predicate with validation *)
let query_predicate ~max_results store predicate =
  (* Validate predicate name *)
  match Query_validation.validate_predicate_name predicate with
  | Error err -> Lwt.return (Error (Query_validation.error_message err))
  | Ok () ->
      Model.query_predicate ~limit:max_results store predicate
      >>= fun facts ->
      let json = `Assoc [
        "predicate", `String predicate;
        "facts", `List (List.map (fun fact -> fact_to_json fact.Model.arguments) facts);
        "count", `Int (List.length facts);
        "limited", `Bool true;
        "max_results", `Int max_results
      ] in
      Lwt.return (Ok json)

(** Execute query with timeout and validation *)
let execute_query ~max_results store query_str ~offset ~limit =
  (* Parse query *)
  match Query_parser.parse_query query_str with
  | None -> Lwt.return (Error (Query_validation.error_message Query_validation.InvalidSyntax))
  | Some query ->
      (* Validate query structure and parameters *)
      match Query_validation.validate_query query offset limit with
      | Error err -> Lwt.return (Error (Query_validation.error_message err))
      | Ok (valid_offset, valid_limit) ->
          (* Enforce max results limit *)
          let limit_to_use = 
            match valid_limit with
            | Some user_limit -> Some (min user_limit max_results)
            | None -> Some max_results
          in
          
          (* Determine execution strategy *)
          let is_join = List.length query.Query_parser.patterns > 1 in
          let use_streaming = is_join && Option.is_some limit_to_use in
          
          (* Execute with timeout *)
          Lwt.catch
            (fun () ->
              Lwt_unix.with_timeout Query_validation.Config.query_timeout (fun () ->
                if use_streaming then
                  let offset_val = Option.value valid_offset ~default:0 in
                  let limit_val = Option.get limit_to_use in
                  
                  Model.execute_query_streaming store query ~offset:offset_val ~limit:limit_val
                  >>= fun result ->
                  let result_json = `Assoc [
                    "results", `List (List.map (fun binding ->
                      `Assoc [
                        "bindings", `List (List.map (fun (var, value) ->
                          `Assoc ["variable", `String var; "value", `String value]
                        ) binding)
                      ]
                    ) result.Model.bindings);
                    "variables", `List (List.map (fun v -> `String v) result.Model.variables);
                  ] in
                  Lwt.return (Ok result_json)
                else
                  Model.execute_query store query
                  >>= fun result ->
                  Lwt.return (Ok (query_result_to_json ?offset:valid_offset ?limit:limit_to_use result))
              )
            )
            (function
              | Lwt_unix.Timeout ->
                  let msg = Printf.sprintf "Query timeout after %.0f seconds - query too expensive. Try limiting predicates or adding more specific constraints." 
                    Query_validation.Config.query_timeout in
                  Lwt.return (Error msg)
              | exn ->
                  Lwt.return (Error (Printf.sprintf "Query error: %s" (Printexc.to_string exn)))
            )
