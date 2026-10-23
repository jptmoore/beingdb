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

(** Error response helper. Always the object shape [{"error": {"code":
    ..., "message": ...}}] -- never a bare string under ["error"] --
    distinguishing transport/runtime failures from query-invalid
    responses (which use [{"valid": false, "errors": [...] }], see
    {!handle_query_language}). [code] defaults to a generic
    ["invalid_request"] for the simpler endpoints that only ever surface
    a plain message; [status] defaults to [400 Bad Request]. *)
let error_response ?(status = `Bad_Request) ?(code = "invalid_request") message =
  Dream.json ~status (Yojson.Safe.to_string (`Assoc [ ("error", `Assoc [ ("code", `String code); ("message", `String message) ]) ]))

(** [Controller.Failure] codes that map to a more specific HTTP status
    than the generic [400]; anything else stays [400 Bad Request]. *)
let status_for_failure_code = function
  | "query_too_long" -> `Payload_Too_Large
  | _ -> `Bad_Request

(** Health check endpoint *)
let handle_root _req =
  json_response (`Assoc [ ("status", `String "OK") ])

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
  let detailed = match Dream.query req "detailed" with Some "true" | Some "1" -> true | _ -> false in
  if detailed then
    let q = Dream.query req "q" in
    let names = Option.map (fun s -> String.split_on_char ',' s |> List.map String.trim |> List.filter (( <> ) "")) (Dream.query req "names") in
    Controller.list_predicates_detailed ?q ?names pack_store
    >>= function
    | Ok json -> json_response json
    | Error msg -> error_response msg
  else
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

(** Count of currently in-flight store-reading requests ([POST /query],
    [GET /predicates], [GET /query/:predicate]), checked against
    [config.max_concurrent_queries]. Safe as plain mutable state: Lwt is
    cooperative, and the check-then-increment in {!with_query_slot}
    never yields, so there is no race between requests. *)
let in_flight_queries = ref 0

(** Run [handler] if fewer than [config.max_concurrent_queries]
    store-reading requests are in flight, otherwise reject with [429]
    ([server_busy]), guarding against resource exhaustion from a flood of
    concurrent requests. Re-applies [config] to {!Query_validation.Config}
    on every call (cheap ref writes; idempotent for a deployment's single
    config), so a [Server_config.t] here is always self-sufficient. *)
let with_query_slot (config : Server_config.t) handler =
  Server_config.apply config;
  if !in_flight_queries >= config.Server_config.max_concurrent_queries then
    error_response ~status:`Too_Many_Requests ~code:"server_busy" "Too many concurrent queries; please retry shortly."
  else (
    incr in_flight_queries;
    Lwt.finalize handler (fun () ->
        decr in_flight_queries;
        Lwt.return_unit))

(** Run a find/where query. Accepts optional ["language"] (only "dsl";
    "core" is rejected as [unsupported_language]) and ["action"]
    ("execute" (default), "validate", "explain" or "diagnose") fields,
    dispatched via {!Controller.run_query}. Request-level ["offset"] and
    ["limit"] fields are rejected as [unsupported_parameter]: paging is
    [limit N]/[offset N] in the query text. Subject to
    {!with_query_slot}. *)
let handle_query_language (config : Server_config.t) pack_store req =
  let open Lwt.Infix in
  with_query_slot config (fun () ->
      Dream.body req
      >>= fun body ->
      match Yojson.Safe.from_string body with
      | exception _ -> error_response ~code:"malformed_request" "The request body is not valid JSON."
      | `Assoc fields -> (
          match List.assoc_opt "query" fields with
          | Some (`String _) when List.mem_assoc "offset" fields || List.mem_assoc "limit" fields ->
              error_response ~code:"unsupported_parameter"
                "Request-level 'offset' and 'limit' are not supported; put 'limit N' and 'offset N' at the end of the query text."
          | Some (`String query_str) -> (
              let language = match List.assoc_opt "language" fields with Some (`String s) -> Some s | _ -> None in
              let action = match List.assoc_opt "action" fields with Some (`String s) -> Some s | _ -> None in
              Controller.run_query ~max_results:config.Server_config.max_results ?language ?action pack_store query_str
              >>= function
              | Controller.Success json -> json_response json
              | Controller.Invalid json -> Dream.json ~status:`Bad_Request (Yojson.Safe.to_string json)
              | Controller.Failure { code; message } -> error_response ~status:(status_for_failure_code code) ~code message)
          | _ -> error_response ~code:"malformed_request" "Missing 'query' field")
      | _ -> error_response ~code:"malformed_request" "Expected a JSON object")

(** The HTTP routes, shared by {!serve} and the tests. *)
let router (config : Server_config.t) pack_store =
  Dream.router [
    Dream.get "/" handle_root;
    Dream.get "/version" handle_version;
    Dream.get "/predicates" (fun req -> with_query_slot config (fun () -> handle_list_predicates pack_store req));
    Dream.get "/query/:predicate" (fun req ->
      let predicate = Dream.param req "predicate" in
      with_query_slot config (fun () -> handle_query config.Server_config.max_results pack_store predicate req));
    Dream.post "/query" (handle_query_language config pack_store);
  ]

(** Start the API server. [?stop], if given, is a promise that triggers
    a graceful shutdown when it resolves (see {!Dream.run}: stops
    accepting new connections but lets in-flight requests finish). *)
let serve ?stop (config : Server_config.t) pack_store port =
  Dream.run ~interface:"0.0.0.0" ~port ?stop (Dream.logger @@ router config pack_store)
