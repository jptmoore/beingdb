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
  | DisconnectedQuery of string list list  (** Positive patterns form more than one connected component; each element is one component's clause strings *)
  | InvalidSyntax             (** Query syntax is invalid *)
  | InvalidPredicateName of string  (** Predicate name contains invalid characters *)

(** Stable machine-readable code for a validation error, e.g.
    ["disconnected_query"], for structured JSON error responses. *)
val error_code : validation_error -> string

(** Get user-friendly error message for a validation error *)
val error_message : validation_error -> string

(** Validate predicate name syntax.
    
    Predicate names must contain only lowercase letters, numbers, and underscores.
    Returns Ok () on success, or Error with InvalidPredicateName.
*)
val validate_predicate_name : string -> (unit, validation_error) result

(** Validate query structure and parameters.
    
    This is the main validation entry point. It checks:
    - Offset is >= 0
    - Limit is > 0
    - Predicate names are well-formed
    - Positive patterns form a single connected component (see {!Query_connectivity})
    - The query contains at least one predicate pattern
    
    Returns Ok (valid_offset, valid_limit) on success, or Error with validation_error.
*)
val validate_query : Query_parser.query -> int option -> int option -> (int option * int option, validation_error) result
