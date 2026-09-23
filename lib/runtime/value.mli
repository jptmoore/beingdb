(** Central typed value representation used throughout BeingDB: source
    parsing, compiled facts, query literals, variable bindings, comparison
    logic, storage encoding and JSON serialization all share this type. *)

type t =
  | Atom of string
  | String of string
  | Lang_string of { value : string; language : string }
  | Integer of int64
  | Decimal of Decimal.t
  | Boolean of bool
  | Year of int
  | Year_month of { year : int; month : int }
  | Date of { year : int; month : int; day : int }
  | Instant of Calendar.instant
  | Uri of string

(** Stable lower-case type name, e.g. ["integer"], ["year_month"]. Used as
    the type-tag component of index paths and in JSON output. *)
val type_name : t -> string

(** Smart constructors that validate and normalize input. *)
val make_lang_string : value:string -> language:string -> (t, string) result

val make_year_month : year:int -> month:int -> (t, string) result
val make_date : year:int -> month:int -> day:int -> (t, string) result
val make_uri : string -> (t, string) result

(** Type-aware equality. Values of different types are never equal, even
    if their textual forms coincide (e.g. [Integer 1979] <> [Year 1979]). *)
val equal : t -> t -> bool

(** Ordering comparison restricted to compatible types (with numeric
    promotion between {!Integer} and {!Decimal}). Returns [Error msg] with
    a human-readable explanation for incompatible or unsupported
    comparisons (e.g. comparing a date with an integer, or ordering two
    atoms, which is not currently supported). *)
val order_compare : t -> t -> (int, string) result

(** Statically decide, from type names alone (as returned by
    {!type_name}), whether two values of those types could ever be
    ordered against each other by {!order_compare} -- mirrors
    [order_compare]'s cases without needing sample values. Used by the
    expressive query language's validator to catch cross-type ordering
    comparisons (e.g. a date compared with an integer) before execution. *)
val order_compatible_types : string -> string -> bool

(** A short, human-readable suggestion for fixing an ordering comparison
    between two incompatible types, e.g. ["Use a date literal such as
    @1970-01-01."] for a [date]/[integer] mismatch. Returns [None] when
    no specific suggestion applies. *)
val comparison_suggestion : left_type:string -> right_type:string -> string option

(** Canonical human-readable string form of a value (not type-tagged).
    Used for JSON payloads and as the readable component of fact
    encoding. Distinct canonical values always canonicalize identically
    (e.g. decimal [0.90] and [0.9] both print as ["0.9"]). *)
val canonical_string : t -> string

(** Fixed-width sortable string for value types that support ordered range
    queries ([Integer], [Decimal], [Year], [Year_month], [Date],
    [Instant]); [None] for other types. *)
val sortable_string : t -> string option

(** [true] for the ordered types ([Integer], [Decimal], [Year],
    [Year_month], [Date], [Instant]) that support {!order_compare} among
    themselves. Used to distinguish a genuine type mismatch between two
    ordered-but-incompatible types (e.g. a date compared with an integer,
    which is almost certainly a mistake) from an ordinary, expected
    absence of ordering for non-ordered types (e.g. a string encountered
    while range-scanning a numeric index branch, which is silently
    excluded rather than treated as an error). *)
val is_ordered_type : t -> bool

(** Index key: a bounded-length string safe to use as a storage path
    segment. Uses {!sortable_string} when available (for ordered types),
    otherwise {!canonical_string}. Long strings are hashed to keep index
    paths a bounded size; equality/order results are always re-verified
    against the fully decoded value, so hashing cannot cause incorrect
    results. *)
val index_key : t -> string

(** Typed JSON representation: [{"type": <type_name>, "value": <string>}].
    Decimal values are always encoded as JSON strings to avoid precision
    loss. *)
val to_json : t -> Yojson.Safe.t

(** Reconstruct a value from its {!type_name} and {!canonical_string}. Used
    to decode stored facts. *)
val of_canonical : type_name:string -> string -> (t, string) result
