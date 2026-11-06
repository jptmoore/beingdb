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
let check_pattern (env : Query_environment.t) predicate arguments line column errors warnings =
  match Query_environment.find env predicate with
  | None ->
      let suggestions = Predicate_suggest.suggest ~arity:(List.length arguments) ~known:(Query_environment.known_names env) predicate in
      errors := Validation_error.Unknown_predicate { predicate; suggestions; line = Some line; column = Some column } :: !errors
  | Some signature ->
      let received = List.length arguments in
      if received <> signature.arity then
        errors := Validation_error.Arity_mismatch { predicate; expected = signature.arity; received; line = Some line; column = Some column } :: !errors
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
                    Validation_error.Literal_type_mismatch
                      { predicate; argument_position = i; expected_types; received_type; line = Some line; column = Some column }
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
      | Pattern { predicate; arguments; line; column } -> check_pattern env predicate arguments line column errors warnings
      | Compare _ | Between _ -> ()
      | Optional inner -> validate_clauses env inner errors warnings
      | Alternatives branches -> List.iter (fun b -> validate_clauses env b errors warnings) branches
      | Negation inner -> validate_clauses env inner errors warnings)
    clauses

(** For every variable that appears as a [Pattern] argument at a
    position with a known predicate, record the union of types observed
    at that position anywhere in the compiled data. Used to statically
    catch comparisons that could never succeed for *any* value the
    variable could hold (e.g. comparing a date-typed variable against an
    integer literal). A variable with no inferable type (never used in a
    recognized pattern) is left out, and its comparisons are left
    unchecked here -- deferred to runtime, exactly as cross-variable
    comparisons already are. *)
let rec collect_var_types (env : Query_environment.t) (var_types : (string, string list) Hashtbl.t) clauses =
  List.iter
    (fun (c : Surface_ast.surface_clause) ->
      match c with
      | Pattern { predicate; arguments; _ } -> (
          match Query_environment.find env predicate with
          | None -> ()
          | Some signature ->
              List.iteri
                (fun i (arg : Query_ast.term) ->
                  match arg with
                  | Query_ast.Variable v ->
                      let observed =
                        match List.nth_opt signature.Query_environment.arguments i with Some a -> a.Query_environment.types | None -> []
                      in
                      let existing = try Hashtbl.find var_types v with Not_found -> [] in
                      Hashtbl.replace var_types v (List.sort_uniq String.compare (existing @ observed))
                  | Query_ast.Literal _ | Query_ast.Wildcard -> ())
                arguments)
      | Compare _ | Between _ -> ()
      | Optional inner -> collect_var_types env var_types inner
      | Alternatives branches -> List.iter (collect_var_types env var_types) branches
      | Negation inner -> collect_var_types env var_types inner)
    clauses

let types_of_term (var_types : (string, string list) Hashtbl.t) (t : Query_ast.term) : string list =
  match t with
  | Query_ast.Literal v -> [ Value.type_name v ]
  | Query_ast.Variable v -> ( match Hashtbl.find_opt var_types v with Some types -> types | None -> [])
  | Query_ast.Wildcard -> []

(** [true] if some combination of the two type sets could be ordered
    against each other; an empty set means "type unknown", which is
    never flagged (nothing to statically disprove). *)
let any_order_compatible left_types right_types =
  left_types = [] || right_types = []
  || List.exists (fun lt -> List.exists (fun rt -> Value.order_compatible_types lt rt) right_types) left_types

(** Only ordering comparisons (< <= > >=, and [between]) can be
    statically wrong for a whole type: equality (=, !=) is always
    well-defined across any two types in this engine (values of
    different types are simply never equal), so it is never flagged. *)
let check_comparison var_types (left : Query_ast.term) (right : Query_ast.term) line column errors =
  let left_types = types_of_term var_types left and right_types = types_of_term var_types right in
  if not (any_order_compatible left_types right_types) then
    let left_type = List.hd (List.sort String.compare left_types) in
    let right_type = List.hd (List.sort String.compare right_types) in
    let message = Printf.sprintf "Cannot compare a %s with a %s." left_type right_type in
    let suggestion = Value.comparison_suggestion ~left_type ~right_type in
    errors :=
      Validation_error.Comparison_type_mismatch { left_type; right_type; message; suggestion; line = Some line; column = Some column } :: !errors

(* [Var contains "text"]: a variable over text, and a bounded, non-empty
   literal string (no wildcards or regular expressions exist to check). *)
let check_contains var_types (left : Query_ast.term) (right : Query_ast.term) line errors =
  let error message = errors := Validation_error.Invalid_contains { message; line = Some line } :: !errors in
  match (left, right) with
  | Query_ast.Variable v, Query_ast.Literal (Value.String text) ->
      let n = String.length text in
      if n = 0 then error "'contains' needs some text to search for, e.g. Title contains \"video\""
      else if n > Query_validation.max_contains_length then
        error (Printf.sprintf "'contains' text is %d characters; the limit is %d" n Query_validation.max_contains_length)
      else
        let types = types_of_term var_types left in
        if types <> [] && not (List.exists (fun t -> List.mem t [ "string"; "lang_string"; "atom" ]) types) then
          error
            (Printf.sprintf "%s holds %s values; 'contains' only matches text (strings and atoms)" v (String.concat ", " types))
  | Query_ast.Variable _, _ -> error "'contains' needs quoted text on the right, e.g. Title contains \"video\""
  | _ -> error "'contains' needs a variable on the left, e.g. Title contains \"video\""

let rec check_comparisons var_types clauses errors =
  List.iter
    (fun (c : Surface_ast.surface_clause) ->
      match c with
      | Pattern _ -> ()
      | Compare { left; operator; right; line; column } -> (
          match operator with
          | Query_ast.Lt | Query_ast.Le | Query_ast.Gt | Query_ast.Ge -> check_comparison var_types left right line column errors
          | Query_ast.Eq | Query_ast.Ne -> ()
          | Query_ast.Contains -> check_contains var_types left right line errors)
      | Between { value; lower; upper; line; column } ->
          check_comparison var_types value lower line column errors;
          check_comparison var_types value upper line column errors
      | Optional inner -> check_comparisons var_types inner errors
      | Alternatives branches -> List.iter (fun b -> check_comparisons var_types b errors) branches
      | Negation inner -> check_comparisons var_types inner errors)
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
  let var_types = Hashtbl.create 16 in
  collect_var_types env var_types surface.where_;
  check_comparisons var_types surface.where_ errors;
  let top_level_positive_vars = positive_variables surface.where_ in
  validate_negation_safety top_level_positive_vars surface.where_ errors;
  let query_vars = all_variables surface.where_ |> List.sort_uniq String.compare in
  let columns = surface.projection.variables in
  let plain_columns = List.filter (fun c -> Core_query.aggregate_of c = None) columns in
  let aggregates = List.sort_uniq compare (List.filter_map Core_query.aggregate_of columns) in
  let only_counts = List.for_all (fun (f, _) -> f = Core_query.Count) aggregates in
  let aggregate_error (f : Core_query.aggregate) message =
    if f = Count then Validation_error.Invalid_count { message } else Validation_error.Invalid_aggregate { message }
  in
  List.iter
    (fun c ->
      let v = match Core_query.aggregate_of c with Some (_, v) -> v | None -> c in
      if not (List.mem v query_vars) then errors := Validation_error.Unbound_projection { variable = v } :: !errors)
    columns;
  List.iter
    (fun ((f : Core_query.aggregate), v) ->
      if List.mem v plain_columns then
        errors :=
          aggregate_error f
            (if f = Count then
               Printf.sprintf
                 "count(%s) counts a variable that is also a 'find' column, so every count would be 1; remove %s from 'find' or count another variable"
                 v v
             else
               Printf.sprintf
                 "%s(%s) aggregates a variable that is also a 'find' column, so each group holds a single %s; remove %s from 'find' or aggregate another variable"
                 (Core_query.aggregate_name f) v v v)
          :: !errors)
    aggregates;
  (* sum/avg need numbers, min/max ordered values; a variable whose type is
     unknown here is left to run time. *)
  let numeric = [ "integer"; "decimal" ] and ordered = [ "integer"; "decimal"; "year"; "year_month"; "date"; "instant" ] in
  List.iter
    (fun ((f : Core_query.aggregate), v) ->
      let name = Core_query.aggregate_column f v in
      let suitable, wanted =
        match f with Sum | Avg -> (numeric, "integer or decimal values") | Min | Max | Count -> (ordered, "numbers, years or dates")
      in
      match Hashtbl.find_opt var_types v with
      | _ when f = Count -> ()
      | None | Some [] -> ()
      | Some types -> (
          match List.filter (fun t -> List.mem t suitable) types with
          | [] ->
              errors :=
                Validation_error.Invalid_aggregate
                  { message = Printf.sprintf "%s needs %s, but %s only holds %s values" name wanted v (String.concat ", " types) }
                :: !errors
          | usable ->
              let ignored = List.filter (fun t -> not (List.mem t usable)) types in
              if ignored <> [] then
                warnings :=
                  {
                    Validation_error.code = "aggregate_ignores_values";
                    message = Printf.sprintf "%s ignores %s's %s values" name v (String.concat ", " ignored);
                    line = None;
                  }
                  :: !warnings;
              let incomparable =
                (f = Min || f = Max) && List.exists (fun a -> List.exists (fun b -> not (Value.order_compatible_types a b)) usable) usable
              in
              if incomparable then
                warnings :=
                  {
                    Validation_error.code = "aggregate_mixed_types";
                    message =
                      Printf.sprintf "%s: %s holds values that cannot be compared with each other (%s); those are skipped" name v
                        (String.concat ", " usable);
                    line = None;
                  }
                  :: !warnings))
    aggregates;
  (* sum/avg add each distinct solution of the named variables once, so a
     pattern that leaves the thing being added up as [_] collapses equal
     values: duration_minutes(_, M) adds two 18-minute works once. *)
  let rec patterns (clauses : Surface_ast.surface_clause list) =
    List.concat_map
      (fun (c : Surface_ast.surface_clause) ->
        match c with
        | Pattern { predicate; arguments; line; _ } -> [ (predicate, arguments, line) ]
        | Optional inner | Negation inner -> patterns inner
        | Alternatives branches -> List.concat_map patterns branches
        | Compare _ | Between _ -> [])
      clauses
  in
  List.iter
    (fun ((f : Core_query.aggregate), v) ->
      if f = Sum || f = Avg then
        List.iter
          (fun (predicate, arguments, line) ->
            if List.mem (Query_ast.Variable v) arguments && List.mem Query_ast.Wildcard arguments then
              warnings :=
                {
                  Validation_error.code = "aggregate_wildcard";
                  message =
                    Printf.sprintf
                      "%s adds each distinct combination of the query's named variables once, and %s(...) leaves an argument as _, so equal %s values there are added once; name that argument (e.g. the thing each %s belongs to) to add every value"
                      (Core_query.aggregate_column f v) predicate v v;
                  line = Some line;
                }
                :: !warnings)
          (patterns surface.where_))
    aggregates;
  List.iter
    (fun (item : Core_query.order_item) ->
      if aggregates <> [] then (
        if not (List.mem item.variable columns) then
          errors :=
            aggregate_error
              (if only_counts then Count else Sum)
              (Printf.sprintf "In a query with %s, 'order by' can only use 'find' columns (%s); %s is not one"
                 (if only_counts then "count(...)" else "aggregates (count, sum, avg, min, max)")
                 (String.concat ", " columns) item.variable)
            :: !errors)
      else if not (List.mem item.variable query_vars) then
        errors := Validation_error.Unbound_order_variable { variable = item.variable } :: !errors)
    surface.order_by;
  let clauses = List.map strip_line surface.where_ in
  let variables = Query_ast.extract_variables clauses in
  let query = { Query_ast.clauses; variables } in
  (match Query_connectivity.check_query query with
  | Ok () -> ()
  | Error groups ->
      errors :=
        Validation_error.Disconnected_query
          { groups; message = "The query contains disconnected pattern groups and would produce a Cartesian product." }
        :: !errors);
  match !errors with
  | _ :: _ -> { core_query = None; errors = List.rev !errors; warnings = List.rev !warnings }
  | [] ->
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
