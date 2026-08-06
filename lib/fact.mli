(** A fully typed fact: a predicate applied to typed arguments. Fact
    identity is derived deterministically from the predicate name, arity
    and canonical typed arguments only -- never from evidence, editorial
    metadata or source information (which this implementation does not
    currently model). *)

type t = { predicate : string; arguments : Value.t list }

val make : string -> Value.t list -> t

(** Deterministic fact ID: an MD5 hex digest of the canonical typed
    proposition (predicate + arity + type-tagged canonical arguments).
    Type tags are part of the input, so [value(item, 1979)],
    [value(item, @1979)] and [value(item, "1979")] all produce different
    IDs. Stable across builds because it only depends on canonical typed
    values. *)
val fact_id : t -> string

(** Canonical, length-prefixed binary-safe encoding of a fact, used as the
    stored value at [/facts/<fact-id>]. *)
val encode : t -> string

val decode : string -> (t, string) result
