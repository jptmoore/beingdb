(** Controller: Business logic layer for query execution and validation *)

(** List predicates with optional samples
    @param samples Number of sample facts per predicate (None for no samples)
    @return JSON representation of predicates *)
val list_predicates : 
  samples:int option -> Db.t -> (Yojson.Safe.t, string) result Lwt.t

(** List predicates with full schema detail and the query-environment
    fingerprint, serialised by {!Query_environment.to_json}: argument
    type signatures, fact counts, bounded typed examples, and any
    declared roles, semantic types and descriptions. [q] filters by
    case-insensitive substring match on the predicate name; [names]
    filters to an exact set of names. *)
val list_predicates_detailed :
  ?q:string -> ?names:string list -> Db.t -> (Yojson.Safe.t, string) result Lwt.t

(** Query single predicate with validation and limiting
    @param max_results Maximum number of results to return
    @param store Pack store
    @param predicate Predicate name
    @return JSON representation of facts or error *)
val query_predicate : 
  max_results:int -> Db.t -> string -> (Yojson.Safe.t, string) result Lwt.t

(** {2 Queries (the find/where language)} *)

(** Outcome of {!run_query}:
    - [Success json]: executed/validated/explained successfully. For all
      three actions (including [execute]), [json] always carries
      [languageVersion]/[environmentFingerprint], letting callers cache
      schema knowledge from ordinary query responses alone.
    - [Invalid json]: a well-formed request whose *query* is invalid --
      [json] always has the shape [{"valid": false, "errors": [...],
      "warnings": [...], "language", "languageVersion",
      "environmentFingerprint"}] (for [validate]/[explain]), or the same
      shape without the explain/validate-specific extras (for
      [execute]). Covers syntax errors, unknown predicates, arity/type
      mismatches, disconnected queries, unsafe negation, and unbound
      projections/ordering, for every action.
    - [Failure { code; message }]: a transport or runtime failure
      unrelated to the query's validity (timeout, internal error, an
      [unsupported_language] ["core"], or a bad [language]/[action]
      parameter). *)
type query_outcome =
  | Success of Yojson.Safe.t
  | Invalid of Yojson.Safe.t
  | Failure of { code : string; message : string }

(** Unified entry point for [POST /query] and the REPL's query commands.
    Queries use the find/where language: [language] may be omitted or
    ["dsl"]; ["core"] fails with [unsupported_language], anything else
    with [unknown_language]. [action] is ["execute"] (default),
    ["validate"], ["explain"] or ["diagnose"] (validation plus
    {!Query_diagnostics} data-aware diagnostics and proven repairs,
    without executing). Execute responses carry [count] (rows returned),
    [total] (rows the query matches), [hasMore] and [truncated]; paging
    is [limit]/[offset] in the query text. *)
val run_query :
  max_results:int ->
  ?language:string ->
  ?action:string ->
  Db.t ->
  string ->
  query_outcome Lwt.t
