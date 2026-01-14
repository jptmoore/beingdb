(** API: Dream-based REST API for querying the Pack backend
    
    Endpoints:
    - GET /predicates - List all predicates
    - GET /query/:predicate - Query all facts for a predicate
    - GET /query/:predicate?args=a,b,_ - Query with pattern matching
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

(** Query a predicate with optional pattern *)
let handle_query pack_store predicate req =
  let args_param = Dream.query req "args" in
  
  match args_param with
  | None ->
      (* Query all facts *)
      Pack_backend.query_all pack_store predicate
      >>= fun results ->
      let json = `Assoc [
        "predicate", `String predicate;
        "facts", `List (List.map fact_to_json results)
      ] in
      json_response json
  
  | Some args_str ->
      (* Query with pattern *)
      let pattern = String.split_on_char ',' args_str |> List.map String.trim in
      Pack_backend.query_predicate pack_store predicate pattern
      >>= fun results ->
      let json = `Assoc [
        "predicate", `String predicate;
        "pattern", `List (List.map (fun s -> `String s) pattern);
        "facts", `List (List.map fact_to_json results)
      ] in
      json_response json

(** Trigger sync (should be authorized in production) *)
let handle_sync git_store pack_store _req =
  Sync.sync git_store pack_store
  >>= fun () ->
  json_response (`Assoc ["status", `String "sync completed"])

(** Build Dream router *)
let router git_store pack_store =
  Dream.router [
    Dream.get "/predicates" 
      (handle_list_predicates pack_store);
    
    Dream.get "/query/:predicate" 
      (fun req ->
        let predicate = Dream.param req "predicate" in
        handle_query pack_store predicate req);
    
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
    Dream.get "/predicates" 
      (handle_list_predicates pack_store);
    
    Dream.get "/query/:predicate" 
      (fun req ->
        let predicate = Dream.param req "predicate" in
        handle_query pack_store predicate req);
  ] in
  
  Dream.run ~port (Dream.logger @@ router)
