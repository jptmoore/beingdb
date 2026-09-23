(** Calendar and UTC instant arithmetic implemented from scratch (no
    external date/time library dependency) using the standard
    days-since-epoch algorithm for the proleptic Gregorian calendar. *)

(** [is_leap_year y] *)
val is_leap_year : int -> bool

(** [days_in_month y m] where [m] is 1-12. *)
val days_in_month : int -> int -> int

(** [valid_date ~year ~month ~day] *)
val valid_date : year:int -> month:int -> day:int -> bool

(** [valid_year_month ~year ~month] *)
val valid_year_month : year:int -> month:int -> bool

(** Days since 1970-01-01 (may be negative). Does not validate the date. *)
val days_from_civil : year:int -> month:int -> day:int -> int64

(** Inverse of {!days_from_civil}: returns (year, month, day). *)
val civil_from_days : int64 -> int * int * int

(** A UTC instant: whole seconds since the Unix epoch plus a nanosecond
    remainder in [0, 999_999_999]. *)
type instant = { seconds : int64; nanos : int }

val compare_instant : instant -> instant -> int
val equal_instant : instant -> instant -> bool

(** Fixed-width sortable string encoding (sign-aware seconds + fixed
    9-digit nanoseconds), suitable for use as an index key. *)
val instant_sortable_string : instant -> string

(** Fixed-width sortable string encoding of a date, based on
    {!days_from_civil}. *)
val date_sortable_string : year:int -> month:int -> day:int -> string

(** Fixed-width sortable string encoding of a year. *)
val year_sortable_string : int -> string

(** Fixed-width sortable string encoding of a year-month. *)
val year_month_sortable_string : year:int -> month:int -> string

(** Parse ["YYYY"], with optional leading ["-"] for negative years. *)
val parse_year : string -> (int, string) result

(** Parse ["YYYY-MM"]. *)
val parse_year_month : string -> (int * int, string) result

(** Parse ["YYYY-MM-DD"]. *)
val parse_date : string -> (int * int * int, string) result

(** Parse an ISO-8601-like instant: ["YYYY-MM-DDTHH:MM:SS"] optionally
    followed by [".fraction"] and a zone designator, either ["Z"] or
    [(+|-)HH:MM]. A zone designator is required. Normalizes to UTC. *)
val parse_instant : string -> (instant, string) result

val format_year : int -> string
val format_year_month : year:int -> month:int -> string
val format_date : year:int -> month:int -> day:int -> string

(** Canonical UTC representation, e.g. ["2026-08-06T12:15:00Z"]. Fractional
    seconds are included only when non-zero. *)
val format_instant : instant -> string
