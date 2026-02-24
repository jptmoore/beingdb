(** DB: Database abstraction layer over storage backends *)

type t = Pack_backend.t

(** Get list of all predicates with their arities *)
val list_predicates : t -> (string * int) list Lwt.t

(** Get list of predicates with sample facts *)
val list_predicates_with_samples : 
  samples:int -> t -> (string * int * Types.arg_value list list option) list Lwt.t

(** Query all facts for a predicate with limit *)
val query_predicate : limit:int -> t -> string -> Types.arg_value list list Lwt.t

(** Check if predicate exists *)
val predicate_exists : t -> string -> bool Lwt.t

(** Execute query using query engine *)
val execute_query : t -> Query_parser.query -> Query_engine.result Lwt.t

(** Execute query with streaming (for joins) *)
val execute_query_streaming : 
  t -> Query_parser.query -> offset:int -> limit:int -> Query_engine.result Lwt.t
