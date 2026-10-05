(** Predicate_declaration: optional, author-declared documentation for
    one predicate. Each part is independently optional:

    - a prose [description];
    - argument [roles] (one per argument, e.g. [Work], [Artist]);
    - per argument, an optional [semantic_type] refining the role.

    Declarations are written in the predicate's source file (see
    [Parse_declaration]), validated at compile time and stored inside the
    predicate's {!Manifest}. They are descriptive only: they never change
    how facts are typed, stored, validated or queried, and semantic
    types are free labels that BeingDB does not check against the facts.

    {[
      %! created_by
      %  Relates a work to the artist or creator who made it.

      %! created_by(Work, Artist)
      %  Relates a work to the artist or creator who made it.

      %! created_by(Work:work, Artist:person)
    ]} *)

type argument = {
  role : string;  (** Variable-style name, e.g. ["Work"]: [[A-Z][A-Za-z0-9_]*]. *)
  semantic_type : string option;  (** Lowercase label, e.g. ["person"]: [[a-z][a-z0-9_]*]. *)
}

type t = private {
  arguments : argument list option;  (** [None]: arguments were not declared (description only). *)
  description : string option;
}

(** Validates role and semantic-type syntax and that roles are distinct.
    An empty or whitespace-only description becomes [None]. A declaration
    with neither arguments nor a description is an [Error]. *)
val make : arguments:argument list option -> description:string option -> (t, string) result

(** Number of declared arguments, or [None] if arguments were not declared. *)
val arity : t -> int option

val valid_role : string -> bool
val valid_semantic_type : string -> bool

(** [signature name t] renders the declaration's signature line in source
    syntax, e.g. ["created_by(Work:work, Artist)"], or just [name] when
    arguments were not declared. *)
val signature : string -> t -> string

(** Pack/manifest encoding: [{"arguments": [{"role": .., "semantic_type": ..}],
    "description": ..}], with absent optional fields (including
    [arguments]) omitted. *)
val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
