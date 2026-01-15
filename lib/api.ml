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
let handle_query_language pack_store req =
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
                  (* Execute query (returns all results) *)
                  Query_engine.execute pack_store query
                  >>= fun result ->
                  (* Apply pagination in result_to_json *)
                  json_response (Query_engine.result_to_json ?offset ?limit result))
          | _ -> error_response "Missing 'query' field")
      | _ -> error_response "Expected JSON object"

(** Build Dream router *)
let router git_store pack_store =
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
      (handle_query_language pack_store);
    
    Dream.post "/sync"
      (handle_sync git_store pack_store);
  ]

(** Start the API server *)
let serve ~port ~git_store ~pack_store =
  Logs.info (fun m -> m "Starting API server on port %d" port);
  Dream.run ~port
    (Dream.logger
    @@ router git_store pack_store)

(** Pack-only server (no Git backend, no sync endpoint) *)
let serve_pack_only pack_store port =
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
      (handle_query_language pack_store);
  ] in
  
  Dream.run ~port (Dream.logger @@ router)
