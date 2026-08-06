(** Standalone entry point for `beingdb-serve`; the real logic lives in
    {!Beingdb.Cli_serve} so it can be shared with the `beingdb serve`
    subcommand. *)
let () = exit (Cmdliner.Cmd.eval Beingdb.Cli_serve.cmd)

