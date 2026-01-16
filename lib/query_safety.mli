(** Query Safety: Public interface for query validation and protection
    
    This module provides centralized query validation and protection configuration.
    Internal validation helpers are hidden to maintain a clean public API.
*)

(** Configuration for query protection *)
module Config : sig
  (** Query timeout in seconds - abort queries that run too long *)
  val query_timeout : float
  
  (** Maximum intermediate results before aborting (prevents Cartesian explosion) *)
  val max_intermediate_results : int
end

(** Validation errors that can occur during query validation *)
type validation_error =
  | InvalidOffset of int      (** Offset was negative *)
  | InvalidLimit of int        (** Limit was zero or negative *)
  | CartesianProduct          (** Same predicate appears multiple times *)
  | InvalidSyntax             (** Query syntax is invalid *)

(** Get user-friendly error message for a validation error *)
val error_message : validation_error -> string

(** Validate query structure and parameters.
    
    This is the main validation entry point. It checks:
    - Offset is >= 0
    - Limit is > 0
    - No duplicate predicates (Cartesian product check)
    
    Returns Ok (valid_offset, valid_limit) on success, or Error with validation_error.
*)
val validate_query : Query_parser.query -> int option -> int option -> (int option * int option, validation_error) result
