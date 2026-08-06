(** Standalone entry point for `beingdb-pull`; the real logic lives in
    {!Beingdb.Cli_pull} so it can be shared with the `beingdb pull`
    subcommand. *)
let () = exit (Cmdliner.Cmd.eval Beingdb.Cli_pull.cmd)

