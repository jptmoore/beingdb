(** Query Safety: Centralized query validation and protection configuration
    
    This module contains all safety limits and validation logic to prevent
    resource exhaustion from expensive or malicious queries.
*)

(** Configuration for query protection *)
module Config = struct
  (** Query timeout in seconds - abort queries that run too long *)
  let query_timeout = 5.0
  
  (** Maximum intermediate results before aborting (prevents Cartesian explosion) *)
  let max_intermediate_results = 10_000
end

(** Validation errors *)
type validation_error =
  | InvalidOffset of int
  | InvalidLimit of int
  | DisconnectedQuery of string list list
  | InvalidSyntax
  | InvalidPredicateName of string

let error_code = function
  | InvalidOffset _ -> "invalid_offset"
  | InvalidLimit _ -> "invalid_limit"
  | DisconnectedQuery _ -> "disconnected_query"
  | InvalidSyntax -> "invalid_syntax"
  | InvalidPredicateName _ -> "invalid_predicate_name"

let error_message = function
  | InvalidOffset n ->
      Printf.sprintf "Invalid offset: must be >= 0 (got %d)" n
  | InvalidLimit n ->
      Printf.sprintf "Invalid limit: must be > 0 (got %d)" n
  | DisconnectedQuery _ ->
      "The query contains disconnected pattern groups and would produce a Cartesian product. Join the groups with a shared variable, or query them separately."
  | InvalidSyntax ->
      "Invalid query syntax. Please check your query format."
  | InvalidPredicateName name when name = "" ->
      "Invalid query structure. Each predicate must have a valid name before parentheses. Note: OR/disjunction (|, ;) is not supported - use separate queries instead."
  | InvalidPredicateName name ->
      "Invalid predicate name '" ^ name ^ "'. Predicate names must contain only lowercase letters, numbers, and underscores."

(** Validate offset parameter *)
let validate_offset = function
  | None -> Ok None
  | Some n when n < 0 -> Error (InvalidOffset n)
  | Some n -> Ok (Some n)

(** Validate limit parameter *)
let validate_limit = function
  | None -> Ok None
  | Some n when n <= 0 -> Error (InvalidLimit n)
  | Some n -> Ok (Some n)

(** A query's positive patterns must form a single connected component
    (see {!Query_connectivity}); otherwise it would execute as an
    unconstrained Cartesian product. Repeated use of the same predicate
    (self-joins, multi-hop chains) is fine as long as the repeats are
    connected via a shared variable. *)
let check_connectivity (query : Query_ast.query) =
  match Query_connectivity.check_query query with Ok () -> Ok () | Error groups -> Error (DisconnectedQuery groups)

(** Validate predicate name syntax *)
let validate_predicate_name name =
  (* Valid predicate names: lowercase letters, numbers, underscores *)
  let is_valid_char = function
    | 'a'..'z' | '0'..'9' | '_' -> true
    | _ -> false
  in
  if String.length name = 0 then
    Error (InvalidPredicateName name)
  else if not (String.for_all is_valid_char name) then
    Error (InvalidPredicateName name)
  else
    Ok ()

(** Validate all predicate names in query (including inside nested
    optional/alternative/negation groups). *)
let validate_predicate_names (query : Query_ast.query) =
  let rec check = function
    | [] -> Ok ()
    | (predicate, _) :: rest -> (
        match validate_predicate_name predicate with
        | Error _ as e -> e
        | Ok () -> check rest)
  in
  check (Query_ast.all_patterns query.clauses)

(** A query must contain at least one predicate pattern (anywhere,
    including nested inside optional/alternative/negation groups) --
    comparisons alone have no facts to bind variables from. *)
let validate_has_pattern (query : Query_ast.query) =
  if Query_ast.all_patterns query.clauses <> [] then Ok () else Error InvalidSyntax

(** Validate query structure and parameters *)
let validate_query query offset limit =
  match validate_offset offset with
  | Error _ as e -> e
  | Ok valid_offset ->
      match validate_limit limit with
      | Error _ as e -> e
      | Ok valid_limit ->
          match validate_predicate_names query with
          | Error _ as e -> e
          | Ok () ->
          match check_connectivity query with
          | Error _ as e -> e
          | Ok () ->
          match validate_has_pattern query with
          | Error _ as e -> e
          | Ok () -> Ok (valid_offset, valid_limit)
