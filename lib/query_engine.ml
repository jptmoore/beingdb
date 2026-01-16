(** Query_engine: Execute queries with streaming joins
    
    This module executes parsed queries against the Pack backend,
    performing joins across multiple predicates.
    
    Join strategy (streaming for large joins):
    1. Stream first predicate left-to-right
    2. For each binding, try to satisfy next predicate
    3. Yield results incrementally as they're found
    4. Skip 'offset' results, collect 'limit' results
    5. Stop immediately when page is full (early cutoff)
    
    Memory usage: O(join depth), not O(total results)
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
  | String s -> Some s
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

(** Count total results by streaming through join without materializing *)
let count_streaming store query =
  if List.length query.patterns = 1 then
    (* Single predicate - just count directly *)
    let pattern = List.hd query.patterns in
    Pack_backend.query_predicate store pattern.name 
      (List.map (function 
        | Atom a -> a 
        | String s -> s 
        | Wildcard -> "_" 
        | Var _ -> "_") pattern.args)
    >|= fun results ->
    List.length results
  else
    (* Multi-predicate join: stream and count without storing *)
    let count = ref 0 in
    let aborted = ref false in
    
    let rec count_patterns bindings patterns =
      if !aborted then Lwt.return_unit
      else
        (* Yield to allow timeout to fire *)
        Lwt.pause () >>= fun () ->
        match patterns with
        | [] ->
            (* Found a valid result, increment count *)
            incr count;
            (* Abort if count gets too large (Cartesian product protection) *)
            if !count > Query_safety.Config.max_intermediate_results then begin
              aborted := true;
              Lwt.return_unit
            end else
              Lwt.return_unit
      
        | pattern :: rest ->
            match pattern_to_args bindings pattern with
            | None -> Lwt.return_unit
            | Some args ->
                Pack_backend.query_predicate store pattern.name args
                >>= fun results ->
                
                (* For each result, continue counting (no storage) *)
                Lwt_list.iter_s (fun result ->
                  (* Yield on EVERY iteration to allow timeout/cancellation *)
                  Lwt.pause () >>= fun () ->
                  if !aborted then Lwt.return_unit
                  else
                    let new_bindings = bind_variables pattern.args result in
                    match merge_bindings bindings new_bindings with
                    | None -> Lwt.return_unit
                    | Some merged -> count_patterns merged rest
                ) results
    in
    
    count_patterns [] query.patterns
    >|= fun () ->
    if !aborted then Query_safety.Config.max_intermediate_results else !count

(** Stream join with early cutoff for paginated queries *)
let execute_streaming store query ~offset ~limit =
  if List.length query.patterns = 1 then
    (* Single predicate - materialize is fine, it's fast *)
    let pattern = List.hd query.patterns in
    Pack_backend.query_predicate store pattern.name 
      (List.map (function 
        | Atom a -> a 
        | String s -> s 
        | Wildcard -> "_" 
        | Var _ -> "_") pattern.args)
    >|= fun results ->
    let bindings = List.map (fun result ->
      bind_variables pattern.args result
    ) results in
    { bindings; variables = query.variables }
  else
    (* Multi-predicate join: stream with early cutoff *)
    let collected = ref [] in
    let skipped = ref 0 in
    let processed = ref 0 in
    
    let rec stream_patterns bindings patterns =
      (* Early cutoff: stop when we've collected enough *)
      if List.length !collected >= limit then
        Lwt.return_unit
      (* Abort if we've processed too many intermediate results (Cartesian product protection) *)
      else if !processed > Query_safety.Config.max_intermediate_results then
        Lwt.return_unit
      else
        (* Yield to allow timeout to fire *)
        Lwt.pause () >>= fun () ->
        match patterns with
        | [] ->
            (* All patterns satisfied - yield this binding *)
            incr processed;
            if !skipped >= offset then begin
              collected := bindings :: !collected;
              Lwt.return_unit
            end else begin
              incr skipped;
              Lwt.return_unit
            end
        
        | pattern :: rest ->
            match pattern_to_args bindings pattern with
            | None -> Lwt.return_unit
            | Some args ->
                Pack_backend.query_predicate store pattern.name args
                >>= fun results ->
                
                (* Process results one at a time with early cutoff *)
                Lwt_list.iter_s (fun result ->
                  (* Yield on EVERY iteration to allow timeout/cancellation *)
                  Lwt.pause () >>= fun () ->
                  if List.length !collected >= limit then
                    Lwt.return_unit  (* Early exit *)
                  else
                    let new_bindings = bind_variables pattern.args result in
                    match merge_bindings bindings new_bindings with
                    | None -> Lwt.return_unit
                    | Some merged -> stream_patterns merged rest
                ) results
    in
    
    stream_patterns [] query.patterns
    >|= fun () ->
    { bindings = List.rev !collected; variables = query.variables }

(** Execute query: returns all results, pagination handled by result_to_json *)
let execute store query =
  (* Single predicate: simple case *)
  if List.length query.patterns = 1 then
    let pattern = List.hd query.patterns in
    Pack_backend.query_predicate store pattern.name 
      (List.map (function 
        | Atom a -> a 
        | String s -> s 
        | Wildcard -> "_" 
        | Var _ -> "_") pattern.args)
    >|= fun results ->
    let bindings = List.map (fun result ->
      bind_variables pattern.args result
    ) results in
    { bindings; variables = query.variables }
  else
    (* Multi-predicate query (join) - compute ALL results with safety limit *)
    let result_count = ref 0 in
    let aborted = ref false in
    
    let rec execute_patterns bindings patterns =
      if !aborted then Lwt.return []
      else
        (* Yield to allow timeout to fire *)
        Lwt.pause () >>= fun () ->
        match patterns with
        | [] ->
            incr result_count;
            (* Abort if we've accumulated too many results (Cartesian product protection) *)
            if !result_count > Query_safety.Config.max_intermediate_results then begin
              aborted := true;
              Lwt.return []
            end else
              Lwt.return [bindings]
        | pattern :: rest ->
            match pattern_to_args bindings pattern with
            | None -> Lwt.return []
            | Some args ->
                Pack_backend.query_predicate store pattern.name args
                >>= fun results ->
                Lwt_list.fold_left_s (fun acc result ->
                  (* Yield on EVERY iteration to allow timeout/cancellation *)
                  Lwt.pause () >>= fun () ->
                  if !aborted then Lwt.return acc
                  else
                    let new_bindings = bind_variables pattern.args result in
                    match merge_bindings bindings new_bindings with
                    | None -> Lwt.return acc
                    | Some merged ->
                        execute_patterns merged rest
                        >|= fun nested_results ->
                        nested_results @ acc
                ) [] results
    in
    
    execute_patterns [] query.patterns
    >|= fun all_bindings ->
    { bindings = all_bindings; variables = query.variables }

(** Format result as JSON with optional pagination *)
let result_to_json ?offset ?limit result =
  let total_count = List.length result.bindings in
  
  (* Apply pagination *)
  let offset_val = Option.value offset ~default:0 in
  let limit_val = Option.value limit ~default:total_count in
  
  let paginated_bindings = 
    result.bindings
    |> (fun l -> List.filteri (fun i _ -> i >= offset_val) l)
    |> (fun l -> List.filteri (fun i _ -> i < limit_val) l)
  in
  
  let bindings_json = List.map (fun binding ->
    let pairs = List.map (fun (var, value) ->
      (var, `String value)
    ) binding in
    `Assoc pairs
  ) paginated_bindings in
  
  let response = [
    "variables", `List (List.map (fun v -> `String v) result.variables);
    "results", `List bindings_json;
    "count", `Int (List.length paginated_bindings);
    "total", `Int total_count;
  ] in
  
  (* Add pagination metadata if used *)
  let response = 
    if offset <> None || limit <> None then
      response @ [
        "offset", `Int offset_val;
        "limit", `Int limit_val;
      ]
    else
      response
  in
  
  `Assoc response
