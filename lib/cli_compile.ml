(** CLI: `compile` -- compile predicates from Irmin Git HEAD into a Pack
    store. Shared by the standalone [beingdb-compile] binary and the
    [beingdb compile] subcommand. *)

open Lwt.Syntax
open Cmdliner

let compile_predicate pack_store git_store predicate_name =
  (* Read predicate content from Irmin Git *)
  let* content_opt = Git_backend.read_predicate git_store predicate_name in

  match content_opt with
  | None ->
      let* () = Lwt_io.eprintlf "  Predicate not found: %s" predicate_name in
      Lwt.return (0, false)
  | Some content ->
      let facts =
        String.split_on_char '\n' content
        |> List.map String.trim
        |> List.filter (fun line -> line <> "" && (not (String.starts_with ~prefix:"%" line)) && not (String.starts_with ~prefix:"#" line))
      in

      (* Parse facts (synchronously) *)
      let parse_results =
        List.map
          (fun fact ->
            match Parse_predicate.parse_fact fact with
            | None -> `Invalid (fact, "not a fact")
            | Some (Error msg) -> `Invalid (fact, msg)
            | Some (Ok (parsed_pred, args)) -> `Valid (parsed_pred, args, fact))
          facts
      in

      (* Log warnings for invalid facts *)
      let* () =
        Lwt_list.iter_s
          (function `Invalid (fact, msg) -> Lwt_io.eprintlf "  Skipping invalid fact: %s (%s)" fact msg | `Valid _ -> Lwt.return_unit)
          parse_results
      in

      (* Extract valid parsed facts *)
      let parsed_facts = List.filter_map (function `Invalid _ -> None | `Valid data -> Some data) parse_results in

      (* If all facts are invalid, skip this predicate entirely *)
      if List.length parsed_facts = 0 && List.length facts > 0 then
        let* () = Lwt_io.eprintlf "✗ %s (no valid facts - not predicate data)" predicate_name in
        Lwt.return (0, false)
      else if List.length parsed_facts = 0 then
        let* () = Lwt_io.printlf "✓ %s (0 facts)" predicate_name in
        Lwt.return (0, false)
      else
        (* Check arity consistency *)
        let arities = List.map (fun (_, args, _) -> List.length args) parsed_facts in
        let unique_arities = List.sort_uniq compare arities in

        let* () =
          if List.length unique_arities > 1 then
            let arity_examples =
              List.map (fun (_, args, fact) -> Printf.sprintf "%s/%d: %s" predicate_name (List.length args) fact) parsed_facts
            in
            let examples_to_show = if List.length arity_examples <= 5 then arity_examples else List.filteri (fun i _ -> i < 5) arity_examples in
            let* () = Lwt_io.eprintlf "  ERROR: Mixed arities in %s" predicate_name in
            let* () = Lwt_list.iter_s (fun ex -> Lwt_io.eprintlf "    %s" ex) examples_to_show in
            Lwt_io.eprintl "  Each predicate file must contain facts with consistent arity"
          else Lwt.return_unit
        in

        (* Warn about mixed argument types per position (allowed, but surfaced
           as a compile-time diagnostic per the schema-inference design). *)
        let* () =
          if List.length unique_arities > 1 then Lwt.return_unit
          else
            let arity = List.hd unique_arities in
            Lwt_list.iter_s
              (fun pos ->
                let types_at_pos = List.map (fun (_, args, _) -> Value.type_name (List.nth args pos)) parsed_facts |> List.sort_uniq String.compare in
                if List.length types_at_pos > 1 then
                  Lwt_io.eprintlf "  Note: %s argument %d has mixed types: %s" predicate_name pos (String.concat ", " types_at_pos)
                else Lwt.return_unit)
              (List.init arity (fun i -> i))
        in

        (* Only write if arity is consistent *)
        let* () =
          if List.length unique_arities > 1 then Lwt.return_unit
          else
            (* Batch write: all facts in single commit *)
            let facts = List.map (fun (_, args, _) -> Fact.make predicate_name args) parsed_facts in
            let message = Printf.sprintf "Compile %s (%d facts)" predicate_name (List.length facts) in
            Pack_backend.write_predicate_batch pack_store predicate_name facts message
        in

        let fact_count = if List.length unique_arities > 1 then 0 else List.length parsed_facts in
        let has_error = List.length unique_arities > 1 in
        let* () = if has_error then Lwt_io.eprintlf "✗ %s (arity mismatch)" predicate_name else Lwt_io.printlf "✓ %s (%d facts)" predicate_name fact_count in
        Lwt.return (fact_count, has_error)

let compile_all git_path pack_path =
  Lwt_main.run
    (let* () = Lwt_io.printl "BeingDB Compile" in
     let* () = Lwt_io.printlf "Source: Irmin Git (%s)" git_path in
     let* () = Lwt_io.printlf "Target: Pack (%s)" pack_path in
     let* () = Lwt_io.printl "" in

     (* Initialize stores - pack with fresh=true to overwrite existing *)
     let* git = Git_backend.init git_path in
     let* pack = Pack_backend.init ~fresh:true pack_path in

     (* List all predicates from Irmin Git *)
     let* predicates = Git_backend.list_predicates git in
     let* () = Lwt_io.printlf "Found %d predicates" (List.length predicates) in
     let* () = Lwt_io.printl "" in

     (* Compile each predicate *)
     let* results =
       Lwt_list.map_s
         (fun predicate_name ->
           let* count, has_error = compile_predicate pack git predicate_name in
           Lwt.return (predicate_name, count, has_error))
         predicates
     in

     let total_facts = List.fold_left (fun acc (_name, count, _) -> acc + count) 0 results in
     let failed_predicates = List.filter_map (fun (name, _, has_error) -> if has_error then Some name else None) results in
     let error_count = List.length failed_predicates in

     let* () = Lwt_io.printl "" in
     let* () =
       if error_count > 0 then
         let* () = Lwt_io.eprintlf "Compilation failed with %d error(s)!" error_count in
         Lwt_list.iter_s (fun pred -> Lwt_io.eprintlf "  Failed: %s" pred) failed_predicates
       else Lwt_io.printl "Compilation complete!"
     in
     let* () = Lwt_io.printlf "Predicates: %d" (List.length predicates) in
     let* () = Lwt_io.printlf "Total facts: %d" total_facts in

     if error_count > 0 then exit 1 else Lwt.return_unit)

let git_path =
  let doc = "Irmin Git store directory" in
  Arg.(value & opt string "./git-store" & info [ "git"; "g" ] ~docv:"DIR" ~doc)

let pack_path =
  let doc = "Output Pack store directory" in
  Arg.(value & opt string "./pack-store" & info [ "pack"; "p" ] ~docv:"DIR" ~doc)

let cmd =
  let doc = "Compile predicates from Irmin Git HEAD to Pack store" in
  let man =
    [
      `S Manpage.s_description;
      `P "Reads predicates from Irmin Git HEAD and compiles them into an Irmin Pack store for fast queries.";
      `P "This is the second step in the workflow: clone → compile → serve";
      `P "Example:";
      `Pre "  beingdb compile";
      `Pre "  beingdb compile --git ./git-store --pack ./pack-store";
    ]
  in
  let info = Cmd.info "compile" ~version:Version.version ~doc ~man in
  Cmd.v info Term.(const compile_all $ git_path $ pack_path)
