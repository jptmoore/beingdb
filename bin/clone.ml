(** Standalone entry point for `beingdb-clone`; the real logic lives in
    {!Beingdb.Cli_clone} so it can be shared with the `beingdb clone`
    subcommand. *)
let () = exit (Cmdliner.Cmd.eval Beingdb.Cli_clone.cmd)

