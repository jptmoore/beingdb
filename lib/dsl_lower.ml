(** Dsl_lower: validates a {!Surface_ast.surface_query} against a
    {!Query_environment} and lowers it into a {!Core_query.t} that the
    existing planner/executor run unchanged. Collects every error found
    (rather than stopping at the first) so validation/explain responses
    can report all problems at once. *)

type result = { core_query : Core_query.t option; errors : Validation_error.t list; warnings : Validation_error.warning list }

(** Recursively collect every variable name mentioned anywhere in a
    surface clause list (including inside nested groups). *)
let rec all_variables clauses =
  List.concat_map
    (fun (c : Surface_ast.surface_clause) ->
      match c with
      | Pattern { arguments; _ } -> List.filter_map (function Query_ast.Variable v -> Some v | _ -> None) arguments
      | Compare { left; right; _ } -> List.filter_map (function Query_ast.Variable v -> Some v | _ -> None) [ left; right ]
      | Between { value; lower; upper; _ } ->
          List.filter_map (function Query_ast.Variable v -> Some v | _ -> None) [ value; lower; upper ]
      | Optional inner -> all_variables inner
      | Alternatives branches -> List.concat_map all_variables branches
      | Negation inner -> all_variables inner)
    clauses

(** Variables bound by positive (non-negated) clauses anywhere in scope:
    descends into [Optional]/[Alternatives] but not [Negation]. *)
let rec positive_variables clauses =
  List.concat_map
    (fun (c : Surface_ast.surface_clause) ->
      match c with
      | Pattern { arguments; _ } -> List.filter_map (function Query_ast.Variable v -> Some v | _ -> None) arguments
      | Compare { left; right; _ } -> List.filter_map (function Query_ast.Variable v -> Some v | _ -> None) [ left; right ]
      | Between { value; lower; upper; _ } ->
          List.filter_map (function Query_ast.Variable v -> Some v | _ -> None) [ value; lower; upper ]
      | Optional inner -> positive_variables inner
      | Alternatives branches -> List.concat_map positive_variables branches
      | Negation _ -> [])
    clauses

(** Validate a single leaf pattern against the environment, returning any
    hard errors and advisory warnings (heterogeneous-position notices). *)
let check_pattern (env : Query_environment.t) predicate arguments line errors warnings =
  match Query_environment.find env predicate with
  | None ->
      let suggestions = Predicate_suggest.suggest ~arity:(List.length arguments) ~known:(Query_environment.known_names env) predicate in
      errors := Validation_error.Unknown_predicate { predicate; suggestions; line = Some line } :: !errors
  | Some signature ->
      let received = List.length arguments in
      if received <> signature.arity then
        errors := Validation_error.Arity_mismatch { predicate; expected = signature.arity; received; line = Some line } :: !errors
      else
        List.iteri
          (fun i (arg : Query_ast.term) ->
            match arg with
            | Query_ast.Literal v -> (
                let expected_types =
                  match List.nth_opt signature.arguments i with Some a -> a.Query_environment.types | None -> []
                in
                let received_type = Value.type_name v in
                if not (List.mem received_type expected_types) then
                  errors :=
                    Validation_error.Literal_type_mismatch { predicate; argument_position = i; expected_types; received_type; line = Some line }
                    :: !errors
                else if List.length expected_types > 1 then
                  warnings :=
                    {
                      Validation_error.code = "heterogeneous_position";
                      message =
                        Printf.sprintf "Predicate '%s' argument %d holds multiple types (%s); this literal matches only %s" predicate i
                          (String.concat ", " expected_types) received_type;
                      line = Some line;
                    }
                    :: !warnings)
            | Query_ast.Variable _ | Query_ast.Wildcard -> ())
          arguments

let strip_line : Surface_ast.surface_clause -> Query_ast.clause =
  let rec go (c : Surface_ast.surface_clause) : Query_ast.clause =
    match c with
    | Pattern { predicate; arguments; _ } -> Query_ast.Pattern { predicate; arguments }
    | Compare { left; operator; right; _ } -> Query_ast.Compare { left; operator; right }
    | Between { value; lower; upper; _ } -> Query_ast.Between { value; lower; upper }
    | Optional inner -> Query_ast.Optional (List.map go inner)
    | Alternatives branches -> Query_ast.Alternatives (List.map (List.map go) branches)
    | Negation inner -> Query_ast.Not_exists (List.map go inner)
  in
  go

let rec validate_clauses env clauses errors warnings =
  List.iter
    (fun (c : Surface_ast.surface_clause) ->
      match c with
      | Pattern { predicate; arguments; line } -> check_pattern env predicate arguments line errors warnings
      | Compare _ | Between _ -> ()
      | Optional inner -> validate_clauses env inner errors warnings
      | Alternatives branches -> List.iter (fun b -> validate_clauses env b errors warnings) branches
      | Negation inner -> validate_clauses env inner errors warnings)
    clauses

(** Check every [not] block's variables are all bound by some positive
    clause elsewhere in the query (classic Datalog "safe negation" rule):
    a variable that only ever appears inside a negation is unbound in
    any binding the query could produce. *)
let rec validate_negation_safety top_level_positive_vars clauses errors =
  List.iter
    (fun (c : Surface_ast.surface_clause) ->
      match c with
      | Pattern _ | Compare _ | Between _ -> ()
      | Optional inner -> validate_negation_safety top_level_positive_vars inner errors
      | Alternatives branches -> List.iter (fun b -> validate_negation_safety top_level_positive_vars b errors) branches
      | Negation inner ->
          let unsafe = List.filter (fun v -> not (List.mem v top_level_positive_vars)) (all_variables inner) |> List.sort_uniq String.compare in
          if unsafe <> [] then errors := Validation_error.Unsafe_negation { variables = unsafe } :: !errors;
          validate_negation_safety top_level_positive_vars inner errors)
    clauses

let lower (env : Query_environment.t) (surface : Surface_ast.surface_query) : result =
  let errors = ref [] in
  let warnings = ref [] in
  validate_clauses env surface.where_ errors warnings;
  let top_level_positive_vars = positive_variables surface.where_ in
  validate_negation_safety top_level_positive_vars surface.where_ errors;
  let query_vars = all_variables surface.where_ |> List.sort_uniq String.compare in
  List.iter
    (fun v -> if not (List.mem v query_vars) then errors := Validation_error.Unbound_projection { variable = v } :: !errors)
    surface.projection.variables;
  List.iter
    (fun (item : Core_query.order_item) ->
      if not (List.mem item.variable query_vars) then errors := Validation_error.Unbound_order_variable { variable = item.variable } :: !errors)
    surface.order_by;
  match !errors with
  | _ :: _ -> { core_query = None; errors = List.rev !errors; warnings = List.rev !warnings }
  | [] ->
      let clauses = List.map strip_line surface.where_ in
      let variables = Query_ast.extract_variables clauses in
      let query = { Query_ast.clauses; variables } in
      let core_query =
        {
          Core_query.query;
          projection = Some surface.projection.variables;
          distinct = surface.projection.distinct;
          order_by = surface.order_by;
          limit = surface.limit;
          offset = surface.offset;
        }
      in
      { core_query = Some core_query; errors = []; warnings = List.rev !warnings }
