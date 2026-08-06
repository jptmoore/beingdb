(** Exact decimal values represented as coefficient * 10^(-scale).

    No OCaml [float] is used so that values retain exact precision.
    The coefficient is bounded by [int64], which bounds the number of
    significant digits a single decimal value can hold (roughly 18-19
    digits). This is documented as a current limitation: extremely
    high precision decimals (more significant digits than fit in an
    int64) are not supported by this first implementation. *)

type t

(** Parse a decimal literal such ["0.92"], ["-3.500"], ["5"].
    Returns [Error msg] for malformed input or coefficients that do
    not fit in an [int64]. *)
val of_string : string -> (t, string) result

(** Build directly from a coefficient and non-negative scale.
    [make coeff scale] represents [coeff * 10^(-scale)]. The result is
    canonicalized (trailing zeros in the fractional part are removed). *)
val make : int64 -> int -> t

(** Canonical string form, e.g. both ["0.90"] and ["0.9"] print as ["0.9"]. *)
val to_string : t -> string

(** Structural equality on the canonical form. *)
val equal : t -> t -> bool

(** Exact comparison, correct across differing scales (e.g. [0.9] vs [0.90000]),
    implemented via arbitrary-precision digit-string comparison so it does
    not suffer from int64 overflow when aligning scales. *)
val compare : t -> t -> int

(** Fixed-width sortable encoding used for index keys. Values are rescaled
    to a common fixed fractional width ([sortable_scale] digits); decimals
    whose canonical scale exceeds this width lose precision *in the index
    key only* (exact equality/comparison via [compare] is unaffected).
    Magnitudes that overflow [int64] after rescaling are saturated to the
    minimum/maximum encodable value (documented limitation). *)
val to_sortable_string : t -> string

(** Number of fractional digits used by [to_sortable_string]. *)
val sortable_scale : int

val coefficient : t -> int64
val scale : t -> int
