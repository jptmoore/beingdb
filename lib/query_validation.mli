(** Query Safety: Public interface for query validation and protection
    
    This module provides centralized query validation and protection configuration.
    Internal validation helpers are hidden to maintain a clean public API.
*)

(** Configuration for query protection. Starts at sensible built-in
    defaults; {!Server_config.apply} may override these once at process
    startup from a server config file. *)
module Config : sig
  (** Query timeout in seconds - abort queries that run too long *)
  val query_timeout : float ref

  (** Maximum intermediate results before aborting (prevents Cartesian explosion) *)
  val max_intermediate_results : int ref

  (** Maximum accepted length (in bytes) of a raw query string, checked
      before parsing *)
  val max_query_length : int ref
end

(** Validation errors that can occur during query validation *)
type validation_error =
  | InvalidOffset of int      (** Offset was negative *)
  | InvalidLimit of int        (** Limit was zero or negative *)
  | DisconnectedQuery of string list list  (** Positive patterns form more than one connected component; each element is one component's clause strings *)
  | InvalidSyntax             (** Query syntax is invalid *)
  | InvalidPredicateName of string  (** Predicate name contains invalid characters *)
  | QueryTooLong of int        (** Raw query string exceeded {!Config.max_query_length}; carries the actual length *)

(** Stable machine-readable code for a validation error, e.g.
    ["disconnected_query"], for structured JSON error responses. *)
val error_code : validation_error -> string

(** Get user-friendly error message for a validation error *)
val error_message : validation_error -> string

(** Reject a raw query string before it is tokenized/parsed if it
    exceeds {!Config.max_query_length}. *)
val check_query_length : string -> (unit, validation_error) result

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
