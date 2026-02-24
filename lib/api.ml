(** API: Dream-based REST API for querying the Pack backend
    
    Endpoints:
    - GET /predicates - List all predicates
    - GET /query/:predicate - Get all facts for a predicate
    - POST /query - Execute queries with pattern matching and joins
    
    All reads go to Pack (fast).
    Updates are done via recompile + redeploy workflow.
*)

(** JSON response helper *)
let json_response data =
  Dream.json (Yojson.Safe.to_string data)

(** Error response helper *)
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

(** List all predicates *)
let handle_list_predicates pack_store req =
  let open Lwt.Infix in
  (* Check for samples query parameter *)
  let samples = 
    match Dream.query req "samples" with
    | None -> None
    | Some s -> 
        match int_of_string_opt s with
        | Some n when n > 0 && n <= 100 -> Some n
        | _ -> None
  in
  
  Controller.list_predicates ~samples pack_store
  >>= function
  | Ok json -> json_response json
  | Error msg -> error_response msg

(** Get all facts for a predicate *)
let handle_query max_results pack_store predicate _req =
  let open Lwt.Infix in
  Controller.query_predicate ~max_results pack_store predicate
  >>= function
  | Ok json -> json_response json
  | Error msg -> error_response msg

(** Execute a query with joins *)
let handle_query_language max_results pack_store req =
  let open Lwt.Infix in
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
              
              Controller.execute_query ~max_results pack_store query_str ~offset ~limit
              >>= (function
                | Ok json -> json_response json
                | Error msg -> error_response msg)
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

