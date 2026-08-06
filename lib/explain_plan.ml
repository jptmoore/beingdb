(** Explain_plan: a deterministic, typed, machine-readable rendition of a
    query's execution plan (as opposed to {!Query_engine.explain}'s
    human-readable prose, which remains available as [planText]
    alongside this structured [plan]). Operation names are stable and
    independent of any Irmin/Pack filesystem detail:

    {v
      predicate_scan, exact_index_lookup, range_index_lookup, filter,
      join, optional_join, union, not_exists,
      project, distinct, sort, offset, limit
    v} *)

let range_constraints (lower : (Value.t * bool) option) (upper : (Value.t * bool) option) =
  let bound operator_incl operator_excl (v, inclusive) =
    `Assoc [ ("operator", `String (if inclusive then operator_incl else operator_excl)); ("value", Value.to_json v) ]
  in
  (match lower with Some b -> [ bound ">=" ">" b ] | None -> [])
  @ (match upper with Some b -> [ bound "<=" "<" b ] | None -> [])

let access_operation (access : Query_planner.access) predicate : Yojson.Safe.t =
  match access with
  | Query_planner.Equality_index { position; value } ->
      `Assoc
        [
          ("operation", `String "exact_index_lookup");
          ("predicate", `String predicate);
          ("argumentPosition", `Int position);
          ("value", Value.to_json value);
        ]
  | Query_planner.Equality_index_on_variable { position; var } ->
      `Assoc
        [
          ("operation", `String "join");
          ("predicate", `String predicate);
          ("argumentPosition", `Int position);
          ("joinVariables", `List [ `String var ]);
        ]
  | Query_planner.Range_index { position; lower; upper } ->
      `Assoc
        [
          ("operation", `String "range_index_lookup");
          ("predicate", `String predicate);
          ("argumentPosition", `Int position);
          ("constraints", `List (range_constraints lower upper));
        ]
  | Query_planner.Full_scan -> `Assoc [ ("operation", `String "predicate_scan"); ("predicate", `String predicate) ]

let rec step_json (s : Query_planner.step) : Yojson.Safe.t =
  match s with
  | Query_planner.Pattern_step { predicate; access; _ } -> access_operation access predicate
  | Query_planner.Optional_step nested -> `Assoc [ ("operation", `String "optional_join"); ("steps", `List (plan_steps_json nested)) ]
  | Query_planner.Alternatives_step branches ->
      `Assoc [ ("operation", `String "union"); ("branches", `List (List.map (fun b -> `List (plan_steps_json b)) branches)) ]
  | Query_planner.Not_exists_step nested -> `Assoc [ ("operation", `String "not_exists"); ("steps", `List (plan_steps_json nested)) ]

and plan_steps_json (p : Query_planner.t) : Yojson.Safe.t list =
  List.map step_json p.steps
  @ List.map (fun clause -> `Assoc [ ("operation", `String "filter"); ("expression", `String (Query_ast.clause_to_string clause)) ]) p.post_filters

(** The structured [plan] array for a lowered query: the planner's steps
    (recursively, for nested groups) followed by the post-execution
    pipeline's own operations (project, distinct, sort, offset, limit),
    in that order, matching {!Core_query.apply}. *)
let build (cq : Core_query.t) : Yojson.Safe.t list =
  let steps = plan_steps_json (Query_planner.plan cq.query) in
  let project_op = `Assoc [ ("operation", `String "project"); ("variables", `List (List.map (fun v -> `String v) (Core_query.projected_variables cq))) ] in
  let distinct_op =
    if cq.distinct then
      [ `Assoc [ ("operation", `String "distinct"); ("variables", `List (List.map (fun v -> `String v) (Core_query.projected_variables cq))) ] ]
    else []
  in
  let sort_op =
    if cq.order_by = [] then []
    else
      [
        `Assoc
          [
            ("operation", `String "sort");
            ( "keys",
              `List
                (List.map
                   (fun (item : Core_query.order_item) ->
                     `Assoc
                       [
                         ("variable", `String item.variable);
                         ("direction", `String (match item.direction with Ascending -> "ascending" | Descending -> "descending"));
                       ])
                   cq.order_by) );
          ];
      ]
  in
  let offset_op = match cq.offset with Some n -> [ `Assoc [ ("operation", `String "offset"); ("count", `Int n) ] ] | None -> [] in
  let limit_op = match cq.limit with Some n -> [ `Assoc [ ("operation", `String "limit"); ("count", `Int n) ] ] | None -> [] in
  steps @ [ project_op ] @ distinct_op @ sort_op @ offset_op @ limit_op

(** [{"patterns": [...], "comparisons": [...]}] -- the lowered core
    query's patterns and comparisons rendered as strings, recursively
    through nested groups, for the explain response's
    [normalizedCoreQuery] field. *)
let rec collect_patterns_and_comparisons (clauses : Query_ast.clause list) =
  List.fold_left
    (fun (patterns, comparisons) (c : Query_ast.clause) ->
      match c with
      | Query_ast.Pattern _ -> (patterns @ [ Query_ast.clause_to_string c ], comparisons)
      | Query_ast.Compare _ | Query_ast.Between _ -> (patterns, comparisons @ [ Query_ast.clause_to_string c ])
      | Query_ast.Optional group | Query_ast.Not_exists group ->
          let p2, c2 = collect_patterns_and_comparisons group in
          (patterns @ p2, comparisons @ c2)
      | Query_ast.Alternatives branches ->
          let p2, c2 =
            List.fold_left
              (fun (pa, ca) branch ->
                let pb, cb = collect_patterns_and_comparisons branch in
                (pa @ pb, ca @ cb))
              ([], []) branches
          in
          (patterns @ p2, comparisons @ c2))
    ([], []) clauses

let normalized_core_query_json (query : Query_ast.query) : Yojson.Safe.t =
  let patterns, comparisons = collect_patterns_and_comparisons query.clauses in
  `Assoc [ ("patterns", `List (List.map (fun s -> `String s) patterns)); ("comparisons", `List (List.map (fun s -> `String s) comparisons)) ]
