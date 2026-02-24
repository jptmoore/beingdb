(** Controller: Business logic layer for query execution and validation *)

(** List predicates with optional samples
    @param samples Number of sample facts per predicate (None for no samples)
    @return JSON representation of predicates *)
val list_predicates : 
  samples:int option -> Db.t -> (Yojson.Safe.t, string) result Lwt.t

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
