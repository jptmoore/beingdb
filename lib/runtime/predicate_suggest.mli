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

(** [suggest_value ~known value]: likely corrections for a constant
    value (an atom or a string's contents) among the [known] values at
    an argument position, most likely first, at most 5, never [value]
    itself. Case, spaces, hyphens and underscores are normalized away;
    a candidate must be within a small edit distance or share words
    (non-numeric, at least 3 characters) making up at least half of the
    two values' words together ([tate] ~ [tate_modern], but not
    [artist_1] ~ [work_1] or ["Scratch Video Volume 1"] ~
    ["The Video Stairs"]). *)
val suggest_value : known:string list -> string -> string list
