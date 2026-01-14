(** Query_engine: Execute queries with joins
    
    This module executes parsed queries against the Pack backend,
    performing joins across multiple predicates.
    
    Join strategy:
    1. Start with the most selective predicate (fewest wildcards)
    2. For each result, bind variables
    3. Query next predicate with bound variables
    4. Repeat until all predicates satisfied
*)

open Lwt.Infix
open Query_parser

(** Variable binding: maps variable names to values *)
type binding = (string * string) list

(** Result of query execution *)
type result = {
  bindings: binding list;  (* List of all variable bindings that satisfy query *)
  variables: string list;  (* Variable names in order *)
}

(** Convert term to concrete value using bindings *)
let resolve_term bindings = function
  | Atom a -> Some a
  | Wildcard -> Some "_"
  | Var v -> 
      (* If variable not in bindings, treat as wildcard for first pattern *)
      match List.assoc_opt v bindings with
      | Some value -> Some value
      | None -> Some "_"

(** Convert pattern to query arguments, resolving variables *)
let pattern_to_args bindings pattern =
  let resolved = List.map (resolve_term bindings) pattern.args in
  if List.for_all Option.is_some resolved then
    Some (List.map Option.get resolved)
  else
    None

(** Bind variables from query result *)
let bind_variables pattern_args result_args =
  List.fold_left2 (fun acc term result ->
    match term with
    | Var v -> (v, result) :: acc
    | _ -> acc
  ) [] pattern_args result_args

(** Merge two bindings, returns None if conflict *)
let merge_bindings b1 b2 =
  let conflicts = List.exists (fun (var, val1) ->
    match List.assoc_opt var b2 with
    | Some val2 when val1 <> val2 -> true
    | _ -> false
  ) b1 in
  
  if conflicts then None
  else 
    (* Only add bindings from b2 that aren't already in b1 *)
    let new_bindings = List.filter (fun (var, _) ->
      not (List.mem_assoc var b1)
    ) b2 in
    Some (b1 @ new_bindings)

(** Execute a single predicate pattern *)
let execute_pattern store bindings pattern =
  match pattern_to_args bindings pattern with
  | None -> Lwt.return []
  | Some args ->
      Pack_backend.query_predicate store pattern.name args
      >|= fun results ->
      (* Bind variables from each result *)
      List.map (fun result ->
        bind_variables pattern.args result
      ) results

(** Execute query with join strategy *)
let execute store query =
  let rec execute_patterns bindings patterns =
    match patterns with
    | [] -> Lwt.return [bindings]
    | pattern :: rest ->
        execute_pattern store bindings pattern
        >>= fun new_bindings_list ->
        (* For each new binding, try to execute remaining patterns *)
        Lwt_list.map_s (fun new_bindings ->
          match merge_bindings bindings new_bindings with
          | None -> Lwt.return []
          | Some merged -> execute_patterns merged rest
        ) new_bindings_list
        >|= List.concat
  in
  
  execute_patterns [] query.patterns
  >|= fun all_bindings ->
  { bindings = all_bindings; variables = query.variables }

(** Format result as JSON *)
let result_to_json result =
  let bindings_json = List.map (fun binding ->
    let pairs = List.map (fun (var, value) ->
      (var, `String value)
    ) binding in
    `Assoc pairs
  ) result.bindings in
  
  `Assoc [
    "variables", `List (List.map (fun v -> `String v) result.variables);
    "results", `List bindings_json;
    "count", `Int (List.length result.bindings);
  ]
