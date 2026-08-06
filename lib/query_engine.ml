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
  | Query_ast.Pattern _ -> Ok true
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

let fetch_candidates store (step : Query_planner.step) bindings =
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
let verify_and_bind (fact : Fact.t) (step : Query_planner.step) bindings =
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
    Cartesian-product intermediate-result safety limit). *)
let execute store query =
  let p = Query_planner.plan query in
  let result_count = ref 0 in
  let aborted = ref false in
  let error = ref None in
  let rec run steps bindings =
    if !aborted then Lwt.return []
    else
      Lwt.pause () >>= fun () ->
      match steps with
      | [] -> (
          match evaluate_post_filters bindings p.post_filters with
          | Error e ->
              error := Some e;
              aborted := true;
              Lwt.return []
          | Ok false -> Lwt.return []
          | Ok true ->
              incr result_count;
              if !result_count > Query_validation.Config.max_intermediate_results then (
                aborted := true;
                Lwt.return [])
              else Lwt.return [ bindings ])
      | step :: rest ->
          fetch_candidates store step bindings >>= (function
          | Error e ->
              error := Some e;
              aborted := true;
              Lwt.return []
          | Ok candidates ->
              Lwt_list.fold_left_s
                (fun acc fact ->
                  Lwt.pause () >>= fun () ->
                  if !aborted then Lwt.return acc
                  else
                    match verify_and_bind fact step bindings with
                    | None -> Lwt.return acc
                    | Some new_bindings -> run rest (new_bindings @ bindings) >|= fun results -> results @ acc)
                [] candidates)
  in
  run p.steps [] >>= fun all ->
  match !error with
  | Some e -> Lwt.return (Error e)
  | None ->
      Lwt.return (Ok { bindings = List.map (ordered_bindings p.variables) all; variables = p.variables })

(** Execute a query with an offset/limit and early cutoff, for efficient
    pagination of joins. *)
let execute_streaming store query ~offset ~limit =
  let p = Query_planner.plan query in
  let collected = ref [] in
  let skipped = ref 0 in
  let processed = ref 0 in
  let aborted = ref false in
  let error = ref None in
  let rec run steps bindings =
    if List.length !collected >= limit then Lwt.return_unit
    else if !processed > Query_validation.Config.max_intermediate_results then Lwt.return_unit
    else if !aborted then Lwt.return_unit
    else
      Lwt.pause () >>= fun () ->
      match steps with
      | [] -> (
          match evaluate_post_filters bindings p.post_filters with
          | Error e ->
              error := Some e;
              aborted := true;
              Lwt.return_unit
          | Ok false -> Lwt.return_unit
          | Ok true ->
              incr processed;
              if !skipped >= offset then (
                collected := bindings :: !collected;
                Lwt.return_unit)
              else (
                incr skipped;
                Lwt.return_unit))
      | step :: rest ->
          fetch_candidates store step bindings >>= (function
          | Error e ->
              error := Some e;
              aborted := true;
              Lwt.return_unit
          | Ok candidates ->
              Lwt_list.iter_s
                (fun fact ->
                  Lwt.pause () >>= fun () ->
                  if List.length !collected >= limit || !aborted then Lwt.return_unit
                  else
                    match verify_and_bind fact step bindings with
                    | None -> Lwt.return_unit
                    | Some new_bindings -> run rest (new_bindings @ bindings))
                candidates)
  in
  run p.steps [] >>= fun () ->
  match !error with
  | Some e -> Lwt.return (Error e)
  | None ->
      let bindings = List.rev_map (ordered_bindings p.variables) !collected in
      Lwt.return (Ok { bindings; variables = p.variables })

(** Explainable plan for a query, without executing it. *)
let explain query = Query_planner.explain (Query_planner.plan query)

