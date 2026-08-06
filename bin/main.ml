(** BeingDB - Main command dispatcher *)

open Cmdliner

let () =
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
      `P "repl - Interactive query REPL against a Pack store";
    ] in
    let info = Cmd.info "beingdb" ~version:"0.1.0" ~doc ~man in
    Cmd.group info
      [
        Beingdb.Cli_clone.cmd;
        Beingdb.Cli_pull.cmd;
        Beingdb.Cli_import.cmd;
        Beingdb.Cli_compile.cmd;
        Beingdb.Cli_serve.cmd;
        Beingdb.Cli_repl.cmd;
      ]
  in
  
  exit (Cmd.eval default_cmd)



