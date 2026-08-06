(** Query_planner: turns a parsed {!Query_ast.query} into an explainable
    execution plan, choosing a positional index (equality or range) for
    each predicate pattern when the query's comparison clauses make one
    available, and falling back to a full predicate scan otherwise.

    Planning is pure (it does not touch the store): it only inspects the
    clause structure. The chosen index is always re-verified against the
    fully decoded, typed fact when the plan is executed, so an imperfect
    planning heuristic can never produce an incorrect result -- only a
    less optimal one. *)

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

type step = { predicate : string; args : arg_plan list; access : access }

type t = { steps : step list; post_filters : Query_ast.clause list; variables : string list }

(** Collect (variable, operator, literal) constraints from comparison and
    between clauses, normalizing [literal OP variable] to
    [variable OP' literal] and expanding [between] into two constraints. *)
let all_variable_constraints (query : Query_ast.query) =
  List.concat_map
    (function
      | Query_ast.Compare { left = Variable v; operator; right = Literal lit } -> [ (v, operator, lit) ]
      | Query_ast.Compare { left = Literal lit; operator; right = Variable v } ->
          [ (v, Query_ast.flip_operator operator, lit) ]
      | Query_ast.Between { value = Variable v; lower = Literal lo; upper = Literal hi } ->
          [ (v, Query_ast.Ge, lo); (v, Query_ast.Le, hi) ]
      | _ -> [])
    query.clauses

let constraint_map (query : Query_ast.query) =
  let tbl = Hashtbl.create 16 in
  List.iter
    (fun (v, op, lit) ->
      let existing = try Hashtbl.find tbl v with Not_found -> [] in
      Hashtbl.replace tbl v (existing @ [ (op, lit) ]))
    (all_variable_constraints query);
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

let plan (query : Query_ast.query) =
  let constraints = constraint_map query in
  let pattern_clauses =
    List.filter (function Query_ast.Pattern _ -> true | _ -> false) query.clauses
  in
  let ordered =
    List.stable_sort
      (fun (a : Query_ast.clause) (b : Query_ast.clause) ->
        match (a, b) with
        | Pattern pa, Pattern pb ->
            compare (pattern_score pb.arguments constraints) (pattern_score pa.arguments constraints)
        | _ -> 0)
      pattern_clauses
  in
  let bound_vars = Hashtbl.create 16 in
  let steps =
    List.map
      (fun clause ->
        let predicate, arguments =
          match clause with
          | Query_ast.Pattern { predicate; arguments } -> (predicate, arguments)
          | _ -> assert false
        in
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
              match
                List.find_opt (function _, Free_variable (_, Some (Eq_constraint _)) -> true | _ -> false) indexed
              with
              | Some (position, Free_variable (_, Some (Eq_constraint value))) ->
                  Equality_index { position; value }
              | _ -> (
                  match
                    List.find_opt
                      (function _, Free_variable (_, Some (Range_constraint _)) -> true | _ -> false)
                      indexed
                  with
                  | Some (position, Free_variable (_, Some (Range_constraint b))) ->
                      Range_index { position; lower = b.lower; upper = b.upper }
                  | _ -> (
                      match List.find_opt (function _, Bound_variable _ -> true | _ -> false) indexed with
                      | Some (position, Bound_variable var) -> Equality_index_on_variable { position; var }
                      | _ -> Full_scan)))
        in
        List.iter
          (function Free_variable (v, _) -> Hashtbl.replace bound_vars v () | _ -> ())
          args_plan;
        { predicate; args = args_plan; access })
      ordered
  in
  let post_filters =
    List.filter (function Query_ast.Compare _ | Query_ast.Between _ -> true | _ -> false) query.clauses
  in
  { steps; post_filters; variables = query.variables }

let access_to_string = function
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

let explain t =
  String.concat "\n"
    (List.map (fun s -> Printf.sprintf "%s: %s" s.predicate (access_to_string s.access)) t.steps)
