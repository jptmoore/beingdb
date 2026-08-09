(** Server_config: safety-limit defaults for [beingdb-serve], optionally
    overridden from a JSON config file (see {!load_file}) so operators
    can guard against resource exhaustion from expensive or malicious
    queries without recompiling. *)

type t = {
  max_results : int;  (** Hard cap on results returned per query *)
  query_timeout : float;  (** Seconds before an executing query is aborted *)
  max_intermediate_results : int;  (** Cap on intermediate join rows before aborting *)
  max_query_length : int;  (** Cap, in bytes, on a raw query string before parsing *)
  max_concurrent_queries : int;  (** Cap on simultaneously in-flight [POST /query] requests *)
}

let default =
  {
    max_results = 1000;
    query_timeout = 5.0;
    max_intermediate_results = 10_000;
    max_query_length = 20_000;
    max_concurrent_queries = 20;
  }

let ( let* ) = Result.bind

let int_field json name ~default:default_value =
  match Yojson.Safe.Util.member name json with
  | `Null -> Ok default_value
  | `Int n -> Ok n
  | _ -> Error (Printf.sprintf "'%s' must be an integer" name)

let float_field json name ~default:default_value =
  match Yojson.Safe.Util.member name json with
  | `Null -> Ok default_value
  | `Int n -> Ok (float_of_int n)
  | `Float f -> Ok f
  | _ -> Error (Printf.sprintf "'%s' must be a number" name)

(** Build a config by overlaying fields present in [json] onto
    {!default}; missing fields fall back to the default, and any field
    present with the wrong JSON type is a hard [Error]. Every numeric
    field must be strictly positive. *)
let of_json json =
  match json with
  | `Assoc _ -> (
      let* max_results = int_field json "max_results" ~default:default.max_results in
      let* query_timeout = float_field json "query_timeout" ~default:default.query_timeout in
      let* max_intermediate_results = int_field json "max_intermediate_results" ~default:default.max_intermediate_results in
      let* max_query_length = int_field json "max_query_length" ~default:default.max_query_length in
      let* max_concurrent_queries = int_field json "max_concurrent_queries" ~default:default.max_concurrent_queries in
      if max_results <= 0 then Error "'max_results' must be > 0"
      else if query_timeout <= 0.0 then Error "'query_timeout' must be > 0"
      else if max_intermediate_results <= 0 then Error "'max_intermediate_results' must be > 0"
      else if max_query_length <= 0 then Error "'max_query_length' must be > 0"
      else if max_concurrent_queries <= 0 then Error "'max_concurrent_queries' must be > 0"
      else Ok { max_results; query_timeout; max_intermediate_results; max_query_length; max_concurrent_queries })
  | _ -> Error "Config file must contain a single JSON object"

let load_file path =
  match Yojson.Safe.from_file path with
  | exception Sys_error msg -> Error msg
  | exception Yojson.Json_error msg -> Error (Printf.sprintf "invalid JSON: %s" msg)
  | json -> of_json json

(** Apply the safety-limit fields to the process-wide, mutable
    {!Query_validation.Config} refs read by the query engine and
    controller. [max_results]/[max_concurrent_queries] are not stored
    here -- callers thread those through explicitly (see {!Api.serve}). *)
let apply (config : t) =
  Query_validation.Config.query_timeout := config.query_timeout;
  Query_validation.Config.max_intermediate_results := config.max_intermediate_results;
  Query_validation.Config.max_query_length := config.max_query_length
