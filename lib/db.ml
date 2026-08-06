(** DB: Database abstraction layer over storage backends *)

open Lwt.Infix

type t = Pack_backend.t

(** Get list of all predicates with their arities *)
let list_predicates store =
  Pack_backend.list_predicates store
  >>= fun predicates ->
  Lwt_list.map_s
    (fun pred -> Pack_backend.predicate_arity store pred >|= fun arity -> (pred, arity))
    predicates

(** Get list of predicates with sample facts *)
let list_predicates_with_samples ~samples store =
  Pack_backend.list_predicates store
  >>= fun predicates ->
  Lwt_list.map_s
    (fun pred ->
      Pack_backend.predicate_arity store pred >>= fun arity ->
      Pack_backend.sample_facts ~limit:samples store pred >|= fun sample_list ->
      (pred, arity, Some sample_list))
    predicates

(** Query all facts for a predicate *)
let query_predicate ~limit store predicate =
  Pack_backend.query_all_limited ~limit store predicate

(** Check if predicate exists *)
let predicate_exists store predicate =
  Pack_backend.get_manifest store predicate >|= Option.is_some

(** Get the inferred schema manifest for a predicate, if any *)
let get_manifest store predicate = Pack_backend.get_manifest store predicate

(** Execute query using query engine *)
let execute_query store query = Query_engine.execute store query

(** Execute query with streaming (for joins) *)
let execute_query_streaming store query ~offset ~limit =
  Query_engine.execute_streaming store query ~offset ~limit

