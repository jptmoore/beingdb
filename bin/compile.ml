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
      Lwt.return (0, false)
  | Some content ->
      let facts = String.split_on_char '\n' content
        |> List.map String.trim
        |> List.filter (fun line -> 
            line <> "" && 
            not (String.starts_with ~prefix:"%" line) &&
            not (String.starts_with ~prefix:"#" line))
      in
      
      (* Parse facts (synchronously) *)
      let parse_results = List.map (fun fact ->
        match Beingdb.Parse_predicate.parse_fact fact with
        | None -> `Invalid fact
        | Some (parsed_pred, args) -> `Valid (parsed_pred, args, fact)
      ) facts in
      
      (* Log warnings for invalid facts *)
      let* () = Lwt_list.iter_s (function
        | `Invalid fact -> Logs_lwt.warn (fun m -> m "  Skipping invalid fact: %s" fact)
        | `Valid _ -> Lwt.return_unit
      ) parse_results in
      
      (* Extract valid parsed facts *)
      let parsed_facts = List.filter_map (function
        | `Invalid _ -> None
        | `Valid data -> Some data
      ) parse_results in
      
      (* Check arity consistency *)
      let arities = List.map (fun (_, args, _) -> List.length args) parsed_facts in
      let unique_arities = List.sort_uniq compare arities in
      
      let* () = 
        if List.length unique_arities > 1 then
          let arity_examples = List.map (fun (_, args, fact) ->
            Printf.sprintf "%s/%d: %s" predicate_name (List.length args) fact
          ) parsed_facts in
          let examples_to_show = 
            if List.length arity_examples <= 5 then arity_examples 
            else List.filteri (fun i _ -> i < 5) arity_examples 
          in
          let* () = Logs_lwt.err (fun m -> m "  ERROR: Mixed arities in %s" predicate_name) in
          let* () = Lwt_list.iter_s (fun ex ->
            Logs_lwt.err (fun m -> m "    %s" ex)
          ) examples_to_show in
          Logs_lwt.err (fun m -> m "  Each predicate file must contain facts with consistent arity")
        else
          Lwt.return_unit
      in
      
      (* Only write if arity is consistent *)
      let* () = 
        if List.length unique_arities > 1 then
          Lwt.return_unit
        else
          Lwt_list.iter_s (fun (_, args, _) ->
            Beingdb.Pack_backend.write_fact pack_store predicate_name args
          ) parsed_facts
      in
      
      let fact_count = if List.length unique_arities > 1 then 0 else List.length parsed_facts in
      let has_error = List.length unique_arities > 1 in
      let* () = 
        if fact_count > 0 then
          Logs_lwt.info (fun m -> m "  ✓ %d facts" fact_count)
        else if has_error then
          Logs_lwt.info (fun m -> m "  ✗ 0 facts (arity mismatch)")
        else
          Logs_lwt.info (fun m -> m "  ✓ 0 facts")
      in
      Lwt.return (fact_count, has_error)

let compile_all git_path pack_path =
  Lwt_main.run (
    let* () = Logs_lwt.info (fun m -> m "BeingDB Compile") in
    let* () = Logs_lwt.info (fun m -> m "Source: Irmin Git (%s)" git_path) in
    let* () = Logs_lwt.info (fun m -> m "Target: Pack (%s)" pack_path) in
    let* () = Logs_lwt.info (fun m -> m "") in
    
    (* Initialize stores - pack with fresh=true to overwrite existing *)
    let* git = Beingdb.Git_backend.init git_path in
    let* pack = Beingdb.Pack_backend.init ~fresh:true pack_path in
    
    let* () = Logs_lwt.info (fun m -> m "Initialized fresh Pack store") in
    
    (* List all predicates from Irmin Git *)
    let* predicates = Beingdb.Git_backend.list_predicates git in
    let* () = Logs_lwt.info (fun m -> m "Found %d predicates in Git HEAD" (List.length predicates)) in
    let* () = Logs_lwt.info (fun m -> m "") in
    
    (* Compile each predicate *)
    let* results = Lwt_list.map_s (fun predicate_name ->
      let* (count, has_error) = compile_predicate pack git predicate_name in
      Lwt.return (predicate_name, count, has_error)
    ) predicates in
    
    let total_facts = List.fold_left (fun acc (_name, count, _) -> acc + count) 0 results in
    let failed_predicates = List.filter_map (fun (name, _, has_error) -> 
      if has_error then Some name else None
    ) results in
    let error_count = List.length failed_predicates in
    
    let* () = Logs_lwt.info (fun m -> m "") in
    let* () = 
      if error_count > 0 then begin
        let* () = Logs_lwt.err (fun m -> m "Compilation failed with %d error(s)!" error_count) in
        Lwt_list.iter_s (fun pred ->
          Logs_lwt.err (fun m -> m "  Failed: %s" pred)
        ) failed_predicates
      end else
        Logs_lwt.info (fun m -> m "Compilation complete!")
    in
    let* () = Logs_lwt.info (fun m -> m "  Predicates: %d" (List.length predicates)) in
    let* () = Logs_lwt.info (fun m -> m "  Total facts: %d" total_facts) in
    
    if error_count > 0 then
      exit 1
    else
      
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
