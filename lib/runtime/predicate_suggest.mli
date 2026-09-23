(** Predicate_suggest: deterministic, inexpensive suggestions for an
    unknown predicate name, used to build helpful validation errors.
    Uses only normalized-name comparison, edit distance, and token
    overlap -- no embeddings. *)

(** [suggest ?arity ~known name] returns up to 5 known predicate names
    ranked as likely corrections for [name], most likely first.
    [known] is the full list of (predicate name, arity) pairs known to
    the query environment. If [arity] is given, predicates with a
    matching arity are ranked ahead of otherwise-equally-close ones. *)
val suggest : ?arity:int -> known:(string * int) list -> string -> string list
