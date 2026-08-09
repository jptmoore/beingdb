(** Query_engine: execute a planned query against the Pack backend.

    Bindings are typed ({!Value.t}), not flattened strings. Positional
    indexes are used per {!Query_planner}'s chosen access method; the
    plan is always re-verified against the fully decoded fact so planning
    mistakes cannot produce incorrect results. Comparison and between
    clauses that were not resolved into an index access are always
    re-checked as post-filters over the final variable bindings -- this
    is also how cross-variable comparisons (e.g. comparing two joined
    variables) and comparisons the planner could not use for indexing are
    handled, and how type-mismatch errors are surfaced to the caller. *)

open Lwt.Infix

type binding = (string * Value.t) list
type result = { bindings : binding list; variables : string list }

let resolve_term bindings = function
  | Query_ast.Literal v -> Ok v
  | Query_ast.Variable v -> (
      match List.assoc_opt v bindings with
      | Some value -> Ok value
      | None -> Error (Printf.sprintf "Unbound variable in comparison: %s" v))
  | Query_ast.Wildcard -> Error "Wildcard cannot be used in a comparison"

let evaluate_clause bindings (clause : Query_ast.clause) =
  match clause with
  | Query_ast.Pattern _ | Query_ast.Optional _ | Query_ast.Alternatives _ | Query_ast.Not_exists _ ->
      (* Never appear as post-filters: only Compare/Between are collected
         into a group's post_filters (see Query_planner.is_post_filter). *)
      Ok true
  | Query_ast.Compare { left; operator; right } -> (
      match (resolve_term bindings left, resolve_term bindings right) with
      | Error e, _ | _, Error e -> Error e
      | Ok l, Ok r -> (
          match operator with
          | Query_ast.Eq -> Ok (Value.equal l r)
          | Query_ast.Ne -> Ok (not (Value.equal l r))
          | Query_ast.Lt -> ( match Value.order_compare l r with Ok c -> Ok (c < 0) | Error e -> Error e)
          | Query_ast.Le -> ( match Value.order_compare l r with Ok c -> Ok (c <= 0) | Error e -> Error e)
          | Query_ast.Gt -> ( match Value.order_compare l r with Ok c -> Ok (c > 0) | Error e -> Error e)
          | Query_ast.Ge -> ( match Value.order_compare l r with Ok c -> Ok (c >= 0) | Error e -> Error e)))
  | Query_ast.Between { value; lower; upper } -> (
      match (resolve_term bindings value, resolve_term bindings lower, resolve_term bindings upper) with
      | Error e, _, _ | _, Error e, _ | _, _, Error e -> Error e
      | Ok v, Ok lo, Ok hi -> (
          match (Value.order_compare v lo, Value.order_compare v hi) with
          | Ok c1, Ok c2 -> Ok (c1 >= 0 && c2 <= 0)
          | Error e, _ | _, Error e -> Error e))

let evaluate_post_filters bindings post_filters =
  let rec go = function
    | [] -> Ok true
    | clause :: rest -> (
        match evaluate_clause bindings clause with
        | Error _ as e -> e
        | Ok false -> Ok false
        | Ok true -> go rest)
  in
  go post_filters

let fetch_candidates store (step : Query_planner.pattern_step) bindings =
  match step.access with
  | Query_planner.Equality_index { position; value } ->
      Pack_backend.equality_lookup store step.predicate position value >|= fun l -> Ok l
  | Query_planner.Equality_index_on_variable { position; var } -> (
      match List.assoc_opt var bindings with
      | Some value -> Pack_backend.equality_lookup store step.predicate position value >|= fun l -> Ok l
      | None -> Lwt.return (Ok []))
  | Query_planner.Range_index { position; lower; upper } ->
      Pack_backend.range_lookup store step.predicate position ~lower ~upper
  | Query_planner.Full_scan -> Pack_backend.query_all store step.predicate >|= fun l -> Ok l

(** Verify a candidate fact against a step's per-position plan and current
    bindings, returning newly-introduced bindings on success. *)
let verify_and_bind (fact : Fact.t) (step : Query_planner.pattern_step) bindings =
  if List.length fact.arguments <> List.length step.args then None
  else
    let rec go args_plan values acc_new =
      match (args_plan, values) with
      | [], [] -> Some acc_new
      | Query_planner.Constant v :: aps, actual :: vs ->
          if Value.equal v actual then go aps vs acc_new else None
      | Query_planner.Wildcard_arg :: aps, _ :: vs -> go aps vs acc_new
      | Query_planner.Bound_variable var :: aps, actual :: vs -> (
          match List.assoc_opt var bindings with
          | Some bound_v when Value.equal bound_v actual -> go aps vs acc_new
          | _ -> None)
      | Query_planner.Free_variable (var, _) :: aps, actual :: vs -> (
          match List.assoc_opt var acc_new with
          | Some existing -> if Value.equal existing actual then go aps vs acc_new else None
          | None -> go aps vs ((var, actual) :: acc_new))
      | _, _ -> None
    in
    go step.args fact.arguments []

let ordered_bindings variables bindings =
  List.filter_map (fun v -> Option.map (fun value -> (v, value)) (List.assoc_opt v bindings)) variables

(** Execute a query, returning all matching results (subject to the
    Cartesian-product intermediate-result safety limit).

    [Optional]/[Alternatives]/[Not_exists] groups are executed by the
    same recursive traversal as plain patterns: [run_group] runs a
    group's steps and then checks its own post-filters before invoking
    its continuation [k]; [Optional_step] falls through to [k] unchanged
    when its nested group has zero matches (left-join semantics);
    [Alternatives_step] runs every branch and unions their contributions;
    [Not_exists_step] falls through to [k] unchanged only when its nested
    group has *zero* matches (negation-as-failure), and is pruned
    otherwise. *)
let execute store query =
  let p = Query_planner.plan query in
  let result_count = ref 0 in
  let aborted = ref false in
  let error = ref None in
  let collected = ref [] in
  let rec run_group (g : Query_planner.t) bindings k =
    run_steps g.steps bindings (fun bindings' ->
        match evaluate_post_filters bindings' g.post_filters with
        | Error e ->
            error := Some e;
            aborted := true;
            Lwt.return_unit
        | Ok false -> Lwt.return_unit
        | Ok true -> k bindings')
  and run_steps steps bindings k =
    if !aborted then Lwt.return_unit
    else
      Lwt.pause () >>= fun () ->
      match steps with
      | [] -> k bindings
      | Query_planner.Pattern_step pstep :: rest ->
          fetch_candidates store pstep bindings >>= (function
          | Error e ->
              error := Some e;
              aborted := true;
              Lwt.return_unit
          | Ok candidates ->
              Lwt_list.iter_s
                (fun fact ->
                  if !aborted then Lwt.return_unit
                  else
                    Lwt.pause () >>= fun () ->
                    match verify_and_bind fact pstep bindings with
                    | None -> Lwt.return_unit
                    | Some new_bindings -> run_steps rest (new_bindings @ bindings) k)
                candidates)
      | Query_planner.Optional_step nested :: rest ->
          let found_any = ref false in
          run_group nested bindings (fun nested_bindings ->
              found_any := true;
              run_steps rest nested_bindings k)
          >>= fun () -> if !aborted || !found_any then Lwt.return_unit else run_steps rest bindings k
      | Query_planner.Alternatives_step branches :: rest ->
          Lwt_list.iter_s
            (fun branch -> if !aborted then Lwt.return_unit else run_group branch bindings (fun b -> run_steps rest b k))
            branches
      | Query_planner.Not_exists_step nested :: rest ->
          let found_any = ref false in
          run_group nested bindings (fun _ ->
              found_any := true;
              Lwt.return_unit)
          >>= fun () -> if !aborted || !found_any then Lwt.return_unit else run_steps rest bindings k
  in
  run_group p [] (fun bindings ->
      incr result_count;
      if !result_count > !Query_validation.Config.max_intermediate_results then (
        aborted := true;
        Lwt.return_unit)
      else (
        collected := bindings :: !collected;
        Lwt.return_unit))
  >>= fun () ->
  match !error with
  | Some e -> Lwt.return (Error e)
  | None ->
      Lwt.return
        (Ok { bindings = List.rev_map (ordered_bindings p.variables) !collected; variables = p.variables })

(** Execute a query with an offset/limit and early cutoff, for efficient
    pagination of joins. Uses the same recursive group traversal as
    {!execute}. *)
let execute_streaming store query ~offset ~limit =
  let p = Query_planner.plan query in
  let collected = ref [] in
  let skipped = ref 0 in
  let processed = ref 0 in
  let aborted = ref false in
  let error = ref None in
  let should_stop () =
    List.length !collected >= limit || !processed > !Query_validation.Config.max_intermediate_results || !aborted
  in
  let rec run_group (g : Query_planner.t) bindings k =
    run_steps g.steps bindings (fun bindings' ->
        match evaluate_post_filters bindings' g.post_filters with
        | Error e ->
            error := Some e;
            aborted := true;
            Lwt.return_unit
        | Ok false -> Lwt.return_unit
        | Ok true -> k bindings')
  and run_steps steps bindings k =
    if should_stop () then Lwt.return_unit
    else
      Lwt.pause () >>= fun () ->
      match steps with
      | [] -> k bindings
      | Query_planner.Pattern_step pstep :: rest ->
          fetch_candidates store pstep bindings >>= (function
          | Error e ->
              error := Some e;
              aborted := true;
              Lwt.return_unit
          | Ok candidates ->
              Lwt_list.iter_s
                (fun fact ->
                  if should_stop () then Lwt.return_unit
                  else
                    Lwt.pause () >>= fun () ->
                    match verify_and_bind fact pstep bindings with
                    | None -> Lwt.return_unit
                    | Some new_bindings -> run_steps rest (new_bindings @ bindings) k)
                candidates)
      | Query_planner.Optional_step nested :: rest ->
          let found_any = ref false in
          run_group nested bindings (fun nested_bindings ->
              found_any := true;
              run_steps rest nested_bindings k)
          >>= fun () -> if should_stop () || !found_any then Lwt.return_unit else run_steps rest bindings k
      | Query_planner.Alternatives_step branches :: rest ->
          Lwt_list.iter_s
            (fun branch ->
              if should_stop () then Lwt.return_unit else run_group branch bindings (fun b -> run_steps rest b k))
            branches
      | Query_planner.Not_exists_step nested :: rest ->
          let found_any = ref false in
          run_group nested bindings (fun _ ->
              found_any := true;
              Lwt.return_unit)
          >>= fun () -> if should_stop () || !found_any then Lwt.return_unit else run_steps rest bindings k
  in
  run_group p [] (fun bindings ->
      incr processed;
      if !skipped >= offset then (
        collected := bindings :: !collected;
        Lwt.return_unit)
      else (
        incr skipped;
        Lwt.return_unit))
  >>= fun () ->
  match !error with
  | Some e -> Lwt.return (Error e)
  | None ->
      let bindings = List.rev_map (ordered_bindings p.variables) !collected in
      Lwt.return (Ok { bindings; variables = p.variables })

(** Explainable plan for a query, without executing it. *)
let explain query = Query_planner.explain (Query_planner.plan query)


