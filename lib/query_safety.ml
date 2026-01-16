(** Query Safety: Centralized query validation and protection configuration
    
    This module contains all safety limits and validation logic to prevent
    resource exhaustion from expensive or malicious queries.
*)

(** Configuration for query protection *)
module Config = struct
  (** Query timeout in seconds - abort queries that run too long *)
  let query_timeout = 2.0
  
  (** Maximum intermediate results before aborting (prevents Cartesian explosion) *)
  let max_intermediate_results = 10_000
end

(** Validation errors *)
type validation_error =
  | InvalidOffset of int
  | InvalidLimit of int
  | CartesianProduct
  | InvalidSyntax

let error_message = function
  | InvalidOffset n ->
      Printf.sprintf "Invalid offset: must be >= 0 (got %d)" n
  | InvalidLimit n ->
      Printf.sprintf "Invalid limit: must be > 0 (got %d)" n
  | CartesianProduct ->
      "Query contains Cartesian product (same predicate appears multiple times). This creates exponential combinations and is not supported. Consider restructuring your query or querying incrementally."
  | InvalidSyntax ->
      "Invalid query syntax"

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

(** Check for duplicate predicates (Cartesian product pattern) *)
let check_cartesian_product query =
  let predicate_names = List.map (fun p -> p.Query_parser.name) query.Query_parser.patterns in
  let unique_predicates = List.sort_uniq String.compare predicate_names in
  if List.length predicate_names <> List.length unique_predicates then
    Error CartesianProduct
  else
    Ok ()

(** Validate query structure and parameters *)
let validate_query query offset limit =
  match validate_offset offset with
  | Error _ as e -> e
  | Ok valid_offset ->
      match validate_limit limit with
      | Error _ as e -> e
      | Ok valid_limit ->
          match check_cartesian_product query with
          | Error _ as e -> e
          | Ok () -> Ok (valid_offset, valid_limit)
