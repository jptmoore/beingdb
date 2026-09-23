(** Query_planner: turns a parsed {!Query_ast.query} into an explainable
    execution plan, choosing a positional index (equality or range) for
    each predicate pattern when the query's comparison clauses make one
    available, and falling back to a full predicate scan otherwise.

    Planning is pure (it does not touch the store): it only inspects the
    clause structure. The chosen index is always re-verified against the
    fully decoded, typed fact when the plan is executed, so an imperfect
    planning heuristic can never produce an incorrect result -- only a
    less optimal one.

    [Optional]/[Alternatives]/[Not_exists] groups are planned recursively
    (each nested group gets its own sub-plan, seeded with whichever
    variables are already bound by the enclosing scope), and executed by
    the same executor as plain patterns -- see {!Query_engine}. Variables
    bound only inside such a group are never treated as bound by the
    *enclosing* scope's later steps, since that binding is conditional
    (optional), branch-specific (alternatives), or nonexistent
    (negation). *)

type bound = { lower : (Value.t * bool) option; upper : (Value.t * bool) option }

type var_constraint = Eq_constraint of Value.t | Range_constraint of bound

type arg_plan =
  | Constant of Value.t
  | Wildcard_arg
  | Bound_variable of string
  | Free_variable of string * var_constraint option

type access =
  | Equality_index of { position : int; value : Value.t }
  | Equality_index_on_variable of { position : int; var : string }
  | Range_index of { position : int; lower : (Value.t * bool) option; upper : (Value.t * bool) option }
  | Full_scan

type pattern_step = { predicate : string; args : arg_plan list; access : access }

type step =
  | Pattern_step of pattern_step
  | Optional_step of t
  | Alternatives_step of t list
  | Not_exists_step of t

and t = { steps : step list; post_filters : Query_ast.clause list; variables : string list }

let is_post_filter = function Query_ast.Compare _ | Query_ast.Between _ -> true | _ -> false

(** Collect (variable, operator, literal) constraints from comparison and
    between clauses in [clauses] (not descending into nested groups --
    each group's constraints are scoped to itself), normalizing
    [literal OP variable] to [variable OP' literal] and expanding
    [between] into two constraints. *)
let all_variable_constraints clauses =
  List.concat_map
    (function
      | Query_ast.Compare { left = Variable v; operator; right = Literal lit } -> [ (v, operator, lit) ]
      | Query_ast.Compare { left = Literal lit; operator; right = Variable v } ->
          [ (v, Query_ast.flip_operator operator, lit) ]
      | Query_ast.Between { value = Variable v; lower = Literal lo; upper = Literal hi } ->
          [ (v, Query_ast.Ge, lo); (v, Query_ast.Le, hi) ]
      | _ -> [])
    clauses

let constraint_map clauses =
  let tbl = Hashtbl.create 16 in
  List.iter
    (fun (v, op, lit) ->
      let existing = try Hashtbl.find tbl v with Not_found -> [] in
      Hashtbl.replace tbl v (existing @ [ (op, lit) ]))
    (all_variable_constraints clauses);
  let result = Hashtbl.create 16 in
  Hashtbl.iter
    (fun v ops ->
      match List.find_opt (fun (op, _) -> op = Query_ast.Eq) ops with
      | Some (_, lit) -> Hashtbl.replace result v (Eq_constraint lit)
      | None ->
          let lower =
            List.find_map
              (fun (op, lit) ->
                match op with
                | Query_ast.Ge -> Some (lit, true)
                | Query_ast.Gt -> Some (lit, false)
                | _ -> None)
              ops
          in
          let upper =
            List.find_map
              (fun (op, lit) ->
                match op with
                | Query_ast.Le -> Some (lit, true)
                | Query_ast.Lt -> Some (lit, false)
                | _ -> None)
              ops
          in
          if lower <> None || upper <> None then Hashtbl.replace result v (Range_constraint { lower; upper }))
    tbl;
  result

let pattern_score (query_arguments : Query_ast.term list) constraints =
  List.fold_left
    (fun acc term ->
      match term with
      | Query_ast.Literal _ -> acc + 2
      | Query_ast.Variable v when Hashtbl.mem constraints v -> acc + 1
      | Query_ast.Variable _ | Query_ast.Wildcard -> acc)
    0 query_arguments

let clause_score constraints = function
  | Query_ast.Pattern { arguments; _ } -> pattern_score arguments constraints
  | Query_ast.Optional _ | Query_ast.Alternatives _ | Query_ast.Not_exists _ -> 0
  | Query_ast.Compare _ | Query_ast.Between _ -> 0

let build_pattern_step ~bound_vars constraints predicate arguments =
  let args_plan =
    List.map
      (fun term ->
        match term with
        | Query_ast.Literal v -> Constant v
        | Query_ast.Wildcard -> Wildcard_arg
        | Query_ast.Variable v ->
            if Hashtbl.mem bound_vars v then Bound_variable v
            else Free_variable (v, Hashtbl.find_opt constraints v))
      arguments
  in
  let indexed = List.mapi (fun i a -> (i, a)) args_plan in
  let access =
    match List.find_opt (function _, Constant _ -> true | _ -> false) indexed with
    | Some (position, Constant value) -> Equality_index { position; value }
    | _ -> (
        match List.find_opt (function _, Free_variable (_, Some (Eq_constraint _)) -> true | _ -> false) indexed with
        | Some (position, Free_variable (_, Some (Eq_constraint value))) -> Equality_index { position; value }
        | _ -> (
            match
              List.find_opt (function _, Free_variable (_, Some (Range_constraint _)) -> true | _ -> false) indexed
            with
            | Some (position, Free_variable (_, Some (Range_constraint b))) ->
                Range_index { position; lower = b.lower; upper = b.upper }
            | _ -> (
                match List.find_opt (function _, Bound_variable _ -> true | _ -> false) indexed with
                | Some (position, Bound_variable var) -> Equality_index_on_variable { position; var }
                | _ -> Full_scan)))
  in
  List.iter (function Free_variable (v, _) -> Hashtbl.replace bound_vars v () | _ -> ()) args_plan;
  { predicate; args = args_plan; access }

(** Plan [clauses] given the set of variables already bound by the
    enclosing scope ([bound_vars], mutated in place as plain patterns
    bind new variables; nested groups always plan against a *copy*, so
    their own bindings never leak back out). *)
let rec plan_clauses ~bound_vars clauses =
  let constraints = constraint_map clauses in
  let step_clauses = List.filter (fun c -> not (is_post_filter c)) clauses in
  let ordered =
    List.stable_sort (fun a b -> compare (clause_score constraints b) (clause_score constraints a)) step_clauses
  in
  let steps =
    List.map
      (function
        | Query_ast.Pattern { predicate; arguments } ->
            Pattern_step (build_pattern_step ~bound_vars constraints predicate arguments)
        | Query_ast.Optional group -> Optional_step (plan_clauses ~bound_vars:(Hashtbl.copy bound_vars) group)
        | Query_ast.Alternatives branches ->
            Alternatives_step (List.map (fun g -> plan_clauses ~bound_vars:(Hashtbl.copy bound_vars) g) branches)
        | Query_ast.Not_exists group -> Not_exists_step (plan_clauses ~bound_vars:(Hashtbl.copy bound_vars) group)
        | Query_ast.Compare _ | Query_ast.Between _ -> assert false)
      ordered
  in
  let post_filters = List.filter is_post_filter clauses in
  { steps; post_filters; variables = Query_ast.extract_variables clauses }

let plan (query : Query_ast.query) =
  let t = plan_clauses ~bound_vars:(Hashtbl.create 16) query.clauses in
  { t with variables = query.variables }

let rec access_to_string = function
  | Equality_index { position; value } ->
      Printf.sprintf "equality_index(position=%d, value=%s)" position (Value.canonical_string value)
  | Equality_index_on_variable { position; var } ->
      Printf.sprintf "equality_index(position=%d, bound_variable=%s)" position var
  | Range_index { position; lower; upper } ->
      let show = function
        | Some (v, incl) -> Printf.sprintf "%s%s" (if incl then "" else "exclusive:") (Value.canonical_string v)
        | None -> "unbounded"
      in
      Printf.sprintf "range_index(position=%d, lower=%s, upper=%s)" position (show lower) (show upper)
  | Full_scan -> "full_scan"

and step_to_lines indent step =
  let pad = String.make indent ' ' in
  match step with
  | Pattern_step s -> [ Printf.sprintf "%s%s: %s" pad s.predicate (access_to_string s.access) ]
  | Optional_step nested -> (pad ^ "optional:") :: plan_to_lines (indent + 2) nested
  | Not_exists_step nested -> (pad ^ "not_exists:") :: plan_to_lines (indent + 2) nested
  | Alternatives_step branches ->
      (pad ^ "either:")
      :: List.concat_map
           (fun branch -> (String.make (indent + 2) ' ' ^ "or:") :: plan_to_lines (indent + 4) branch)
           branches

and plan_to_lines indent t = List.concat_map (step_to_lines indent) t.steps

let explain t = String.concat "\n" (plan_to_lines 0 t)

