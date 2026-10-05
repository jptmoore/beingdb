(** Query_environment: dataset-aware predicate metadata used by the
    expressive query language for validation, suggestions, and
    introspection. Built deterministically from the compiled store's
    per-predicate schema manifests (see {!Manifest}), via any
    {!Runtime_store.S}. Types, counts and examples are always inferred
    from the facts; roles, semantic types and descriptions come from
    optional author declarations ({!Predicate_declaration}) and are
    [None] when none were declared. *)

type argument_signature = {
  position : int;
  types : string list;  (** Observed value types at this position. *)
  role : string option;  (** Declared role, e.g. ["Work"]. *)
  semantic_type : string option;  (** Declared semantic type, e.g. ["person"]. *)
}

type predicate_signature = {
  name : string;
  arity : int;
  arguments : argument_signature list;
  count : int;
  examples : Value.t list list;
  description : string option;  (** Declared description. *)
}

type t = {
  predicates : predicate_signature list;
  by_name : (string, predicate_signature) Hashtbl.t;
  fingerprint : string;
  language_version : string;
}

(** Expressive query-language generation identifier, included in the
    fingerprint so that a language change invalidates cached prompts. *)
val language_version : string

module Make (Store : Runtime_store.S) : sig
  (** Build the environment directly from the store's predicate manifests.
      [examples] bounds how many example facts are captured per predicate
      (default 3). *)
  val build : ?examples:int -> Store.t -> t Lwt.t

  (** Load (or, currently, deterministically rebuild) the query
      environment for a store. This is the single entry point the REPL and
      the HTTP server both call, so they can never construct the
      environment differently. *)
  val load_or_build : ?examples:int -> Store.t -> t Lwt.t
end

val find : t -> string -> predicate_signature option

(** All known predicate (name, arity) pairs, for suggestion generation. *)
val known_names : t -> (string * int) list

(** Introspection JSON for one predicate: [name], [arity], [count],
    optional [description], [arguments] (each with [position], [types]
    and optional [role]/[semanticType]) and [examples]. Optional fields
    are omitted when undeclared. *)
val predicate_to_json : predicate_signature -> Yojson.Safe.t

(** The full introspection document ([GET /predicates?detailed=true]):
    [predicates] ([predicates] defaults to every predicate in [t]),
    [environmentFingerprint] and [languageVersion]. *)
val to_json : ?predicates:predicate_signature list -> t -> Yojson.Safe.t
