(** The runtime storage boundary: the read-only operations the query
    engine and query environment need from a compiled BeingDB store.

    Expressed purely in BeingDB terms (predicates, argument positions,
    typed values, facts, manifests) -- no Irmin, filesystem or Unix
    concepts. Implementations must honour these semantics:

    - [equality_lookup t p i v]: every fact of [p] whose argument [i] is
      {!Value.equal} to [v].
    - [range_lookup t p i ~lower ~upper]: every fact of [p] whose
      argument [i] lies within the (inclusive when the flag is [true])
      bounds under {!Value.order_compare}; values of non-ordered types
      are silently excluded, while an ordered value that cannot be
      compared with the bound is an [Error]. No bounds -> [Ok []].
    - [query_all]/[sample_facts]: all facts of a predicate, or at most
      [limit] of them (default 20).
    - [list_predicates]/[get_manifest]: compiled predicate names and
      their schema manifests.

    Result order is unspecified. *)

module type S = sig
  type t

  val list_predicates : t -> string list Lwt.t
  val get_manifest : t -> string -> Manifest.t option Lwt.t
  val query_all : t -> string -> Fact.t list Lwt.t
  val sample_facts : ?limit:int -> t -> string -> Fact.t list Lwt.t
  val equality_lookup : t -> string -> int -> Value.t -> Fact.t list Lwt.t

  val range_lookup :
    t ->
    string ->
    int ->
    lower:(Value.t * bool) option ->
    upper:(Value.t * bool) option ->
    (Fact.t list, string) result Lwt.t
end
