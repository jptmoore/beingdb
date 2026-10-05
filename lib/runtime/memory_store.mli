(** Memory_store: a small in-memory compiled store, for tests and
    portability experiments -- not a production backend.

    Facts are "compiled" into the same logical layout as a native pack
    ({!Pack_layout.predicate_entries}) held in an in-memory tree, and
    read back through {!Pack_layout.Make}. It therefore exercises the
    exact pack interpretation and query engine used natively, with no
    Irmin, filesystem or Unix dependency. *)

include Runtime_store.S

val create : unit -> t

(** Compile one predicate's facts into the store, replacing its
    manifest (mirrors [Pack_backend.write_predicate_batch]). *)
val add_predicate : ?declaration:Predicate_declaration.t -> t -> string -> Fact.t list -> unit

(** Build a store from facts of any predicates, grouped by predicate. *)
val of_facts : Fact.t list -> t
