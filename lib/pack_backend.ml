(** Pack Backend: High-performance runtime snapshot
    
    Structure:
    - One directory per predicate
    - One node per fact
    - Arguments encoded in the path
    - Optimized for lookup and joins
    - Disk-based persistent storage using Irmin Pack
*)

open Lwt.Syntax

module Conf = struct
  let entries = 32
  let stable_hash = 256
  let contents_length_header = Some `Varint
  let inode_child_order = `Seeded_hash
  let forbid_empty_dir_persistence = false
end

module StoreMaker = Irmin_pack_unix.KV(Conf)
module Store = StoreMaker.Make(Irmin.Contents.String)
module Store_info = Irmin_unix.Info(Store.Info)

let info message = Store_info.v ~author:"beingdb" "%s" message

type t = Store.t

(** Pack configuration with minimal indexing strategy for GC support *)
let pack_config ?(fresh=false) path =
  Irmin_pack.config path
    ~fresh
    ~indexing_strategy:Irmin_pack.Indexing_strategy.minimal

let create ~fname = 
  Lwt_main.run (
    let config = pack_config fname in
    let* repo = Store.Repo.v config in
    Store.main repo
  )

let init ?(fresh=false) path =
  let config = pack_config ~fresh path in
  let* repo = Store.Repo.v config in
  Store.main repo

(** Encode fact arguments as a path: predicate(a,b,c) -> /predicate/a/b/c *)
let fact_to_path predicate_name args =
  predicate_name :: args

(** Recursively collect all paths under a prefix *)
let rec collect_paths store prefix =
  let* entries = Store.list store prefix in
  Lwt_list.fold_left_s (fun acc (step, _tree) ->
    let step_str = Irmin.Type.to_string Store.Path.step_t step in
    let new_path = prefix @ [step_str] in
    (* Check if this is a node (directory) or contents (leaf) *)
    let* is_leaf = Store.mem store new_path in
    if is_leaf then
      Lwt.return (new_path :: acc)
    else
      let* sub_paths = collect_paths store new_path in
      Lwt.return (sub_paths @ acc)
  ) [] entries

(** Recursively collect all paths under a tree with optional pagination *)
let rec collect_paths_from_tree ?offset ?length tree prefix =
  let* entries = Store.Tree.list tree [] ?offset ?length in
  Lwt_list.fold_left_s (fun acc (step, subtree) ->
    let step_str = Irmin.Type.to_string Store.Tree.step_t step in
    let new_path = prefix @ [step_str] in
    let* kind = Store.Tree.kind subtree [] in
    match kind with
    | Some `Contents -> Lwt.return (new_path :: acc)
    | Some `Node ->
        let* sub_paths = collect_paths_from_tree subtree new_path in
        Lwt.return (sub_paths @ acc)
    | None -> Lwt.return acc
  ) [] entries

(** Query facts matching pattern (use "_" for wildcards) 
    Uses native offset/limit for single-predicate queries without wildcards *)
let query_predicate ?offset ?limit store predicate_name pattern =
  let prefix = [ predicate_name ] in
  
  (* Check if pattern has wildcards *)
  let has_wildcards = List.exists (fun p -> p = "_") pattern in
  
  let* all_paths = 
    if has_wildcards then
      (* Pattern has wildcards - need to collect all then filter *)
      collect_paths store prefix
    else
      (* No wildcards and single predicate - can use native pagination *)
      let length = limit in
      let* tree_opt = Store.find_tree store prefix in
      match tree_opt with
      | None -> Lwt.return []
      | Some tree ->
          collect_paths_from_tree ?offset ?length tree prefix
  in
  
  let matches_pattern path =
    match path with
    | [] -> false
    | _pred :: args ->
        if List.length args <> List.length pattern then false
        else
          List.for_all2 (fun arg pat ->
            pat = "_" || arg = pat
          ) args pattern
  in
  
  let results = all_paths
    |> List.filter matches_pattern
    |> List.map (function _pred :: args -> args | [] -> [])
  in
  
  (* Apply offset/limit manually if we couldn't use native pagination *)
  let results = 
    if has_wildcards then
      let results = match offset with
        | None -> results
        | Some off -> List.filteri (fun i _ -> i >= off) results
      in
      match limit with
      | None -> results
      | Some lim -> List.filteri (fun i _ -> i < lim) results
    else
      results  (* Already paginated by native offset/length *)
  in
  
  Lwt.return results

(** Query all facts for a predicate *)
let query_all store predicate_name =
  let prefix = [ predicate_name ] in
  let* all_paths = collect_paths store prefix in
  all_paths
  |> List.map (function _pred :: args -> args | [] -> [])
  |> Lwt.return

let list_predicates store =
  let* entries = Store.list store [] in
  entries
  |> List.map (fun (step, _tree) -> 
      Irmin.Type.to_string Store.Path.step_t step)
  |> Lwt.return

(** Get the arity of a predicate by sampling the first fact *)
let get_predicate_arity store predicate_name =
  let prefix = [ predicate_name ] in
  let* all_paths = collect_paths store prefix in
  match all_paths with
  | [] -> Lwt.return None
  | path :: _ ->
      (* Extract arity from path: predicate/arg1/arg2/... -> arity = number of args *)
      match path with
      | _ :: args -> Lwt.return (Some (List.length args))
      | [] -> Lwt.return None

(** List all predicates with their arities *)
let list_predicates_with_arity store =
  let* predicates = list_predicates store in
  Lwt_list.map_s (fun pred ->
    let* arity = get_predicate_arity store pred in
    match arity with
    | Some a -> Lwt.return (pred, a)
    | None -> Lwt.return (pred, 0)  (* Empty predicate has arity 0 *)
  ) predicates

let write_fact store predicate_name args =
  let path = fact_to_path predicate_name args in
  Store.set_exn store path "" ~info:(info "Materialize fact")

let clear store =
  Store.remove_exn store [] ~info:(info "Clear all facts")
