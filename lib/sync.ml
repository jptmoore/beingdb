(** Sync: Materialize Git predicates into Pack snapshots
    
    Process:
    1. Read all predicates from Git backend
    2. Parse facts and encode into Pack paths
    3. Create new immutable Pack snapshot
    4. Atomic swap of runtime snapshot
    
    This module orchestrates the Git → Pack pipeline.
*)

open Lwt.Infix

(** Encode predicate into Pack store as path-based nodes *)
let encode_to_pack pack_store predicate_name facts =
  let open Lwt_list in
  
  let write_fact fact =
    match Parse_predicate.parse_fact fact with
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

