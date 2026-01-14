(** Compile predicates from Irmin Git HEAD to Pack store *)

open Lwt.Syntax
open Cmdliner

let compile_predicate pack_store git_store predicate_name =
  let* () = Logs_lwt.info (fun m -> m "Compiling %s..." predicate_name) in
  
  (* Read predicate content from Irmin Git *)
  let* content_opt = Beingdb.Git_backend.read_predicate git_store predicate_name in
  
  match content_opt with
  | None ->
      let* () = Logs_lwt.warn (fun m -> m "  Predicate not found: %s" predicate_name) in
      Lwt.return 0
  | Some content ->
      let facts = String.split_on_char '\n' content
        |> List.map String.trim
        |> List.filter (fun line -> 
            line <> "" && 
            not (String.starts_with ~prefix:"%" line) &&
            not (String.starts_with ~prefix:"#" line))
      in
      
      (* Parse and write each fact to Pack *)
      let* () = Lwt_list.iter_s (fun fact ->
        match Beingdb.Parse_predicate.parse_fact fact with
        | None -> 
            Logs_lwt.warn (fun m -> m "  Skipping invalid fact: %s" fact)
        | Some (_pred, args) ->
            Beingdb.Pack_backend.write_fact pack_store predicate_name args
      ) facts in
      
      let* () = Logs_lwt.info (fun m -> m "  ✓ %d facts" (List.length facts)) in
      Lwt.return (List.length facts)

let compile_all git_path pack_path =
  Lwt_main.run (
    let* () = Logs_lwt.info (fun m -> m "BeingDB Compile") in
    let* () = Logs_lwt.info (fun m -> m "Source: Irmin Git (%s)" git_path) in
    let* () = Logs_lwt.info (fun m -> m "Target: Pack (%s)" pack_path) in
    let* () = Logs_lwt.info (fun m -> m "") in
    
    (* Initialize stores *)
    let* git = Beingdb.Git_backend.init git_path in
    let* pack = Beingdb.Pack_backend.init pack_path in
    
    let* () = Logs_lwt.info (fun m -> m "Clearing existing Pack store...") in
    let* () = Beingdb.Pack_backend.clear pack in
    
    (* List all predicates from Irmin Git *)
    let* predicates = Beingdb.Git_backend.list_predicates git in
    let* () = Logs_lwt.info (fun m -> m "Found %d predicates in Git HEAD" (List.length predicates)) in
    let* () = Logs_lwt.info (fun m -> m "") in
    
    (* Compile each predicate *)
    let* fact_counts = Lwt_list.map_s (fun predicate_name ->
      let* count = compile_predicate pack git predicate_name in
      Lwt.return (predicate_name, count)
    ) predicates in
    
    let total_facts = List.fold_left (fun acc (_name, count) -> acc + count) 0 fact_counts in
    
    let* () = Logs_lwt.info (fun m -> m "") in
    let* () = Logs_lwt.info (fun m -> m "Compilation complete!") in
    let* () = Logs_lwt.info (fun m -> m "  Predicates: %d" (List.length predicates)) in
    let* () = Logs_lwt.info (fun m -> m "  Total facts: %d" total_facts) in
    
    Lwt.return_unit
  )

let git_path =
  let doc = "Irmin Git store directory" in
  Arg.(value & opt string "./git-store" & info ["git"; "g"] ~docv:"DIR" ~doc)

let pack_path =
  let doc = "Output Pack store directory" in
  Arg.(value & opt string "./pack-store" & info ["pack"; "p"] ~docv:"DIR" ~doc)

let cmd =
  let doc = "Compile predicates from Irmin Git HEAD to Pack store" in
  let man = [
    `S Manpage.s_description;
    `P "Reads predicates from Irmin Git HEAD and compiles them into an Irmin Pack store for fast queries.";
    `P "This is the second step in the workflow: clone → compile → serve";
    `P "Example:";
    `Pre "  beingdb compile";
    `Pre "  beingdb compile --git ./git-store --pack ./pack-store";
  ] in
  let info = Cmd.info "compile" ~version:"0.1.0" ~doc ~man in
  Cmd.v info Term.(const compile_all $ git_path $ pack_path)

let () =
  Fmt_tty.setup_std_outputs ();
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  exit (Cmd.eval cmd)
