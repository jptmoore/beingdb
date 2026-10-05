(** Predicate_declaration: optional, author-declared documentation for
    one predicate -- argument roles, optional semantic argument types and
    an optional prose description.

    Declarations are written in the predicate's source file (see
    [Parse_declaration]), validated at compile time and stored inside the
    predicate's {!Manifest}. They are descriptive only: they never change
    how facts are typed, stored, validated or queried, and semantic
    types are free labels that BeingDB does not check against the facts.

    {[
      %! created_by(Work:work, Creator:person)
      %  Relates a work to the person who created it.
    ]} *)

type argument = {
  role : string;  (** Variable-style name, e.g. ["Work"]: [[A-Z][A-Za-z0-9_]*]. *)
  semantic_type : string option;  (** Lowercase label, e.g. ["person"]: [[a-z][a-z0-9_]*]. *)
}

type t = private { arguments : argument list; description : string option }

(** Validates role and semantic-type syntax and that roles are distinct.
    An empty or whitespace-only description becomes [None]. *)
val make : arguments:argument list -> description:string option -> (t, string) result

val arity : t -> int
val valid_role : string -> bool
val valid_semantic_type : string -> bool

(** [signature name t] renders the declaration in its source syntax,
    e.g. ["created_by(Work:work, Creator:person)"]. *)
val signature : string -> t -> string

(** Pack/manifest encoding: [{"arguments": [{"role": .., "semantic_type": ..}],
    "description": ..}], with absent optional fields omitted. *)
val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
