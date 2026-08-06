(** DB: Database abstraction layer over storage backends *)

type t = Pack_backend.t

(** Get list of all predicates with their arities *)
val list_predicates : t -> (string * int) list Lwt.t

(** Get list of predicates with sample facts *)
val list_predicates_with_samples :
  samples:int -> t -> (string * int * Fact.t list option) list Lwt.t

(** Query all facts for a predicate with limit *)
val query_predicate : limit:int -> t -> string -> Fact.t list Lwt.t

(** Check if predicate exists *)
val predicate_exists : t -> string -> bool Lwt.t

(** Get the inferred schema manifest for a predicate, if any *)
val get_manifest : t -> string -> Manifest.t option Lwt.t

(** Execute query using query engine *)
val execute_query : t -> Query_ast.query -> (Query_engine.result, string) result Lwt.t

(** Execute query with streaming (for joins) *)
val execute_query_streaming :
  t -> Query_ast.query -> offset:int -> limit:int -> (Query_engine.result, string) result Lwt.t

