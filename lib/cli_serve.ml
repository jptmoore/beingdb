(** CLI: `serve` -- serve queries from a Pack store. Shared by the
    standalone [beingdb-serve] binary and the [beingdb serve] subcommand. *)

open Cmdliner

let resolve_config config_path max_results_override =
  let base =
    match config_path with
    | None -> Server_config.default
    | Some path -> (
        match Server_config.load_file path with
        | Ok c -> c
        | Error msg ->
            Printf.eprintf "Invalid --config file %s: %s\n%!" path msg;
            exit 1)
  in
  match max_results_override with Some n -> { base with Server_config.max_results = n } | None -> base

(** A promise that resolves on SIGTERM/SIGINT, passed to {!Dream.run} as
    [~stop] so the server stops accepting new connections and drains
    requests already in flight instead of being hard-killed (important
    for rolling restarts/redeploys behind a load balancer). *)
let shutdown_promise () =
  let stop, wake_stop = Lwt.wait () in
  let handle_signal signal_name _ =
    Logs.info (fun m -> m "Received %s, shutting down (draining in-flight requests)..." signal_name);
    if Lwt.state stop = Lwt.Sleep then Lwt.wakeup_later wake_stop ()
  in
  ignore (Lwt_unix.on_signal Sys.sigterm (handle_signal "SIGTERM"));
  ignore (Lwt_unix.on_signal Sys.sigint (handle_signal "SIGINT"));
  stop

let serve pack_path port max_results_override config_path =
  Fmt_tty.setup_std_outputs ();
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  let config = resolve_config config_path max_results_override in
  Server_config.apply config;
  let stop = shutdown_promise () in
  (* Initialize Pack store first, read-only: beingdb-serve never writes,
     and each replica behind a load balancer should have its own copy of
     the compiled store rather than sharing one opened for writing. *)
  let pack =
    Lwt_main.run
      (let open Lwt.Syntax in
       let* () = Logs_lwt.info (fun m -> m "BeingDB Server") in
       let* () = Logs_lwt.info (fun m -> m "Pack store: %s" pack_path) in
       Pack_backend.init ~readonly:true pack_path)
  in

  (* Then start Dream server (which takes over event loop) *)
  Logs.info (fun m -> m "Starting API server on port %d" port);
  Logs.info (fun m -> m "Max results per query: %d" config.Server_config.max_results);
  Logs.info (fun m -> m "Query timeout: %.1fs" config.Server_config.query_timeout);
  Logs.info (fun m -> m "Max intermediate results: %d" config.Server_config.max_intermediate_results);
  Logs.info (fun m -> m "Max query length: %d bytes" config.Server_config.max_query_length);
  Logs.info (fun m -> m "Max concurrent queries: %d" config.Server_config.max_concurrent_queries);
  Api.serve ~stop config pack port;
  Logs.info (fun m -> m "Server stopped")

let pack_path =
  let doc = "Path to Pack store directory" in
  Arg.(value & opt string "./pack" & info [ "pack"; "p" ] ~docv:"DIR" ~doc)

let port =
  let doc = "Server port" in
  Arg.(value & opt int 8080 & info [ "port" ] ~docv:"PORT" ~doc)

let max_results =
  let doc = "Maximum number of results per query (hard limit); overrides the config file's max_results if given" in
  Arg.(value & opt (some int) None & info [ "max-results" ] ~docv:"NUM" ~doc)

let config_path =
  let doc =
    "Path to a JSON config file setting safety limits (max_results, query_timeout, max_intermediate_results, \
     max_query_length, max_concurrent_queries); missing fields fall back to sensible defaults"
  in
  Arg.(value & opt (some string) None & info [ "config" ] ~docv:"FILE" ~doc)

let cmd =
  let doc = "Serve queries from Pack store" in
  let man =
    [
      `S Manpage.s_description;
      `P "Starts a read-only query server backed by Irmin Pack store.";
      `P "Example:";
      `Pre "  beingdb serve --pack ./pack --port 8080 --max-results 5000";
      `P "Example with a config file guarding against expensive/malicious queries:";
      `Pre "  beingdb serve --pack ./pack --config ./beingdb.config.json";
    ]
  in
  let info = Cmd.info "serve" ~version:Version.version ~doc ~man in
  Cmd.v info Term.(const serve $ pack_path $ port $ max_results $ config_path)
