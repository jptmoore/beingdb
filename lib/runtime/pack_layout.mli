(** Pack_layout: BeingDB's logical compiled-pack layout, independent of
    how the underlying key/value tree is physically stored.

    {[
      /facts/<fact-id>                                     -> canonical encoded fact
      /index/<predicate>/_all/<fact-id>                    -> "" (full predicate scan bucket)
      /index/<predicate>/<position>/<type>/<key>/<fact-id> -> "" (positional index)
      /meta/<predicate>                                    -> JSON schema manifest
    ]}

    A fact ID is the SHA-256 hex digest of the canonical typed
    proposition (see {!Fact.fact_id}). The native adapter
    ([Beingdb_pack_unix.Pack_backend]) stores this tree in Irmin Pack;
    {!Make} interprets it over any {!READER} and yields a
    {!Runtime_store.S}. *)

type path = string list

val facts_path : string -> path
val meta_path : string -> path
val index_all_dir : string -> path
val index_key_dir : string -> int -> string -> string -> path
val index_type_branch : string -> int -> string -> path

(** Every [(path, contents)] entry that compiling [facts] for
    [predicate] contributes to the pack: fact bodies, the [_all] scan
    bucket, positional index entries, and the predicate's manifest. *)
val predicate_entries : string -> Fact.t list -> (path * string) list

(** Minimal read-only access to a compiled pack tree. [find] returns the
    contents stored at a path; [list] returns the child step names of a
    directory (in any order), or [[]] if the path is absent. *)
module type READER = sig
  type t

  val find : t -> path -> string option Lwt.t
  val list : t -> path -> string list Lwt.t
end

module Make (R : READER) : sig
  include Runtime_store.S with type t = R.t

  val get_fact : t -> string -> Fact.t option Lwt.t
  val query_all_limited : ?limit:int -> t -> string -> Fact.t list Lwt.t
  val predicate_fact_count : t -> string -> int Lwt.t
  val predicate_arity : t -> string -> int Lwt.t

  (** [pattern] has one entry per argument position: [Some v] requires
      equality at that position, [None] matches anything. *)
  val query_predicate_pattern : t -> string -> Value.t option list -> Fact.t list Lwt.t
end
