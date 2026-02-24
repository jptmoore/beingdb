(** DB: Database abstraction layer over storage backends *)

open Lwt.Infix

type t = Pack_backend.t

(** Get list of all predicates with their arities *)
let list_predicates store =
  Pack_backend.list_predicates_with_arity store

(** Get list of predicates with sample facts *)
let list_predicates_with_samples ~samples store =
  Pack_backend.list_predicates_with_arity_and_samples ~samples store

(** Query all facts for a predicate *)
let query_predicate ~limit store predicate =
  Pack_backend.query_all_limited ~limit store predicate

(** Check if predicate exists *)
let predicate_exists store predicate =
  Pack_backend.query_all_limited ~limit:1 store predicate
  >>= fun results ->
  Lwt.return (List.length results > 0)

(** Execute query using query engine *)
let execute_query store query =
  Query_engine.execute store query

(** Execute query with streaming (for joins) *)
let execute_query_streaming store query ~offset ~limit =
  Query_engine.execute_streaming store query ~offset ~limit
