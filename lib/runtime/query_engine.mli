(** Query_engine: execute a planned query against any compiled store
    satisfying {!Runtime_store.S}. This is the single implementation of
    BeingDB query semantics, shared by every storage adapter. *)

type binding = (string * Value.t) list
type result = { bindings : binding list; variables : string list }

(** Human-readable query plan explanation, without executing. *)
val explain : Query_ast.query -> string

module Make (Store : Runtime_store.S) : sig
  (** Execute a query, returning all matching results (subject to the
      Cartesian-product intermediate-result safety limit). [Error msg] is
      returned for type-mismatched comparisons (e.g. comparing a date with
      an integer) or unbound comparison variables. *)
  val execute : Store.t -> Query_ast.query -> (result, string) Stdlib.result Lwt.t

  (** Execute a query with an offset/limit and early cutoff, for efficient
      pagination of joins. *)
  val execute_streaming :
    Store.t -> Query_ast.query -> offset:int -> limit:int -> (result, string) Stdlib.result Lwt.t
end
