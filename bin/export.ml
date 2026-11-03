(** Standalone entry point for `beingdb-export`; the real logic lives in
    {!Beingdb.Cli_export} so it can be shared with the `beingdb export`
    subcommand. *)
let () = exit (Cmdliner.Cmd.eval Beingdb.Cli_export.cmd)
