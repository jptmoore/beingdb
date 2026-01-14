(** Sync: Materialize Git predicates into Pack snapshots
    
    Process:
    1. Read all predicates from Git backend
    2. Parse facts and encode into Pack paths
    3. Create new immutable Pack snapshot
    4. Atomic swap of runtime snapshot
    
    This module orchestrates the Git → Pack pipeline.
*)

open Lwt.Infix

(** Parse a single fact into predicate name and arguments
    Example: "created(tina_keane, she)." -> ("created", ["tina_keane"; "she"])
*)
let parse_fact fact =
  let fact = String.trim fact in
  let fact = 
    if String.ends_with ~suffix:"." fact then
      String.sub fact 0 (String.length fact - 1)
    else fact
  in
  
  match String.index_opt fact '(' with
  | None -> None
  | Some idx ->
      let predicate = String.sub fact 0 idx in
      let rest = String.sub fact (idx + 1) (String.length fact - idx - 1) in
      let rest = 
        if String.ends_with ~suffix:")" rest then
          String.sub rest 0 (String.length rest - 1)
        else rest
      in
      let args = 
        String.split_on_char ',' rest
        |> List.map String.trim
      in
      Some (predicate, args)

(** Encode predicate into Pack store as path-based nodes *)
let encode_to_pack pack_store predicate_name facts =
  let open Lwt_list in
  
  let write_fact fact =
    match parse_fact fact with
    | None -> Lwt.return_unit
    | Some (_pred, args) ->
        Pack_backend.write_fact pack_store predicate_name args
  in
  
  iter_s write_fact facts

(** Sync a single predicate from Git to Pack *)
let sync_predicate git_store pack_store predicate_name =
  Git_backend.read_predicate git_store predicate_name
  >>= function
  | None -> 
      Logs_lwt.info (fun m -> m "Predicate not found: %s" predicate_name)
  | Some content ->
      let facts = String.split_on_char '\n' content 
                  |> List.filter (fun s -> String.trim s <> "") in
      encode_to_pack pack_store predicate_name facts
      >>= fun () ->
      Logs_lwt.info (fun m -> m "Synced predicate: %s (%d facts)" predicate_name (List.length facts))

(** Sync all predicates from Git to Pack *)
let sync git_store pack_store =
  Logs_lwt.info (fun m -> m "Starting Git → Pack sync")
  >>= fun () ->
  (* Clear pack store before syncing *)
  Pack_backend.clear pack_store
  >>= fun () ->
  Git_backend.list_predicates git_store
  >>= fun predicates ->
  Lwt_list.iter_s (sync_predicate git_store pack_store) predicates
  >>= fun () ->
  Logs_lwt.info (fun m -> m "Sync completed: %d predicates" (List.length predicates))

