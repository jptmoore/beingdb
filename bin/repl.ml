(** Standalone entry point for `beingdb-repl`; the real logic lives in
    {!Beingdb.Cli_repl} so it can be shared with the `beingdb repl`
    subcommand. *)
let () = exit (Cmdliner.Cmd.eval Beingdb.Cli_repl.cmd)
