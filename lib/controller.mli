(** Controller: Business logic layer for query execution and validation *)

(** List predicates with optional samples
    @param samples Number of sample facts per predicate (None for no samples)
    @return JSON representation of predicates *)
val list_predicates : 
  samples:int option -> Db.t -> (Yojson.Safe.t, string) result Lwt.t

(** List predicates with full schema detail (argument type signatures,
    fact counts, bounded typed examples) and the query-environment
    fingerprint. [q] filters by case-insensitive substring match on the
    predicate name; [names] filters to an exact set of names. *)
val list_predicates_detailed :
  ?q:string -> ?names:string list -> Db.t -> (Yojson.Safe.t, string) result Lwt.t

(** Query single predicate with validation and limiting
    @param max_results Maximum number of results to return
    @param store Pack store
    @param predicate Predicate name
    @return JSON representation of facts or error *)
val query_predicate : 
  max_results:int -> Db.t -> string -> (Yojson.Safe.t, string) result Lwt.t

(** Execute complex query with validation, timeout, and result limiting
    @param max_results Maximum number of results to return
    @param store Pack store
    @param query_str Query string to parse
    @param offset Optional offset for pagination
    @param limit Optional limit for pagination
    @return JSON representation of results or error *)
val execute_query : 
  max_results:int -> 
  Db.t -> 
  string -> 
  offset:int option -> 
  limit:int option -> 
  (Yojson.Safe.t, string) result Lwt.t

(** {2 Expressive query language and unified query dispatch} *)

(** Outcome of {!run_query}: a well-formed successful response, a
    well-formed but invalid query (structured validation errors), or a
    hard failure (parse error, unsafe query, execution error, or a bad
    [language]/[action] parameter). *)
type query_outcome =
  | Success of Yojson.Safe.t
  | Invalid of Yojson.Safe.t
  | Failure of string

(** Unified entry point for [POST /query] and the REPL's query commands.
    [language] is ["core"] (default) or ["dsl"]; [action] is ["execute"]
    (default), ["validate"], or ["explain"]. The DSL path shares the same
    planner/executor as the core language via {!Core_query} and
    {!Dsl_lower}. *)
val run_query :
  max_results:int ->
  ?language:string ->
  ?action:string ->
  Db.t ->
  string ->
  offset:int option ->
  limit:int option ->
  query_outcome Lwt.t
