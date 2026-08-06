(** Standalone entry point for `beingdb-import`; the real logic lives in
    {!Beingdb.Cli_import} so it can be shared with the `beingdb import`
    subcommand. *)
let () = exit (Cmdliner.Cmd.eval Beingdb.Cli_import.cmd)

