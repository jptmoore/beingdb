(** Server_config: safety-limit defaults for [beingdb-serve], optionally
    overridden from a JSON config file so operators can guard against
    resource exhaustion from expensive or malicious queries without
    recompiling.

    Example config file:
    {v
    {
      "max_results": 1000,
      "query_timeout": 5.0,
      "max_intermediate_results": 10000,
      "max_query_length": 20000,
      "max_concurrent_queries": 20
    }
    v}
    Any field may be omitted; omitted fields fall back to {!default}. *)

type t = {
  max_results : int;  (** Hard cap on results returned per query *)
  query_timeout : float;  (** Seconds before an executing query is aborted *)
  max_intermediate_results : int;  (** Cap on intermediate join rows before aborting *)
  max_query_length : int;  (** Cap, in bytes, on a raw query string before parsing *)
  max_concurrent_queries : int;  (** Cap on simultaneously in-flight [POST /query] requests *)
}

(** Built-in defaults, matching BeingDB's previous hardcoded limits. *)
val default : t

(** Build a config by overlaying fields present in the given JSON object
    onto {!default}. [Error msg] if the JSON isn't an object, a present
    field has the wrong type, or a numeric field isn't strictly
    positive. *)
val of_json : Yojson.Safe.t -> (t, string) result

(** Read and parse a JSON config file. [Error msg] if the file can't be
    read, isn't valid JSON, or fails {!of_json}'s validation. *)
val load_file : string -> (t, string) result

(** Push the safety-limit fields into the process-wide
    {!Query_validation.Config} refs. Call once at server startup, after
    resolving the effective config. *)
val apply : t -> unit
