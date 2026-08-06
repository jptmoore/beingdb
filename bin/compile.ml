(** Standalone entry point for `beingdb-compile`; the real logic lives in
    {!Beingdb.Cli_compile} so it can be shared with the `beingdb compile`
    subcommand. *)
let () = exit (Cmdliner.Cmd.eval Beingdb.Cli_compile.cmd)

