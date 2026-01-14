(** BeingDB - Main command dispatcher *)

open Cmdliner

let () =
  Fmt_tty.setup_std_outputs ();
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  
  (* Load subcommand modules *)
  let clone_cmd = 
    let doc = "Clone remote Git repository into Irmin Git (shallow)" in
    let info = Cmd.info "clone" ~version:"0.1.0" ~doc in
    Cmd.v info (Term.ret (Term.const (`Help (`Auto, None))))
  in
  
  let pull_cmd =
    let doc = "Pull updates from remote and merge into Irmin Git" in
    let info = Cmd.info "pull" ~version:"0.1.0" ~doc in
    Cmd.v info (Term.ret (Term.const (`Help (`Auto, None))))
  in
  
  let import_cmd =
    let doc = "Import flat files into Irmin Git (development tool)" in
    let info = Cmd.info "import" ~version:"0.1.0" ~doc in
    Cmd.v info (Term.ret (Term.const (`Help (`Auto, None))))
  in
  
  let compile_cmd =
    let doc = "Compile predicates from Irmin Git HEAD to Pack store" in
    let info = Cmd.info "compile" ~version:"0.1.0" ~doc in
    Cmd.v info (Term.ret (Term.const (`Help (`Auto, None))))
  in
  
  let serve_cmd =
    let doc = "Serve queries from Pack store" in
    let info = Cmd.info "serve" ~version:"0.1.0" ~doc in
    Cmd.v info (Term.ret (Term.const (`Help (`Auto, None))))
  in
  
  let default_cmd =
    let doc = "Logic-based knowledge store with Git and Pack backends" in
    let man = [
      `S Manpage.s_description;
      `P "BeingDB is a logic-based knowledge store that separates human collaboration (Git) from machine queries (Pack).";
      `P "See 'beingdb COMMAND --help' for subcommand usage.";
      `S Manpage.s_commands;
      `P "clone - Clone remote repository";
      `P "pull - Pull and merge updates";
      `P "import - Import flat files (dev only)";
      `P "compile - Compile Git to Pack";
      `P "serve - Serve queries from Pack";
    ] in
    let info = Cmd.info "beingdb" ~version:"0.1.0" ~doc ~man in
    Cmd.group info [clone_cmd; pull_cmd; import_cmd; compile_cmd; serve_cmd]
  in
  
  exit (Cmd.eval default_cmd)
