(** Query_environment: dataset-aware predicate metadata used by the
    expressive query language for validation, suggestions, and
    introspection. Built deterministically from the compiled Pack
    store's per-predicate schema manifests (see {!Manifest}) -- no
    user-authored schema is required or read. *)

type argument_signature = { position : int; types : string list }

type predicate_signature = {
  name : string;
  arity : int;
  arguments : argument_signature list;
  count : int;
  examples : Value.t list list;
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

(** Build the environment directly from the store's predicate manifests.
    [examples] bounds how many example facts are captured per predicate
    (default 3). *)
val build : ?examples:int -> Pack_backend.t -> t Lwt.t

(** Load (or, currently, deterministically rebuild) the query
    environment for a store. This is the single entry point the REPL and
    the HTTP server both call, so they can never construct the
    environment differently. *)
val load_or_build : ?examples:int -> Pack_backend.t -> t Lwt.t

val find : t -> string -> predicate_signature option

(** All known predicate (name, arity) pairs, for suggestion generation. *)
val known_names : t -> (string * int) list
