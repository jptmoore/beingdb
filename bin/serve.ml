(** Serve queries from Pack store only *)

open Cmdliner

let serve pack_path port =
  (* Initialize Pack store first *)
  let pack = Lwt_main.run (
    let open Lwt.Syntax in
    let* () = Logs_lwt.info (fun m -> m "BeingDB Server") in
    let* () = Logs_lwt.info (fun m -> m "Pack store: %s" pack_path) in
    Beingdb.Pack_backend.init pack_path
  ) in
  
  (* Then start Dream server (which takes over event loop) *)
  Logs.info (fun m -> m "Starting API server on port %d" port);
  Beingdb.Api.serve_pack_only pack port

let pack_path =
  let doc = "Path to Pack store directory" in
  Arg.(value & opt string "./pack" & info ["pack"; "p"] ~docv:"DIR" ~doc)

let port =
  let doc = "Server port" in
  Arg.(value & opt int 8080 & info ["port"] ~docv:"PORT" ~doc)

let cmd =
  let doc = "Serve queries from Pack store" in
  let man = [
    `S Manpage.s_description;
    `P "Starts a read-only query server backed by Irmin Pack store.";
    `P "Example:";
    `Pre "  beingdb serve --pack ./pack --port 8080";
  ] in
  let info = Cmd.info "serve" ~version:"0.1.0" ~doc ~man in
  Cmd.v info Term.(const serve $ pack_path $ port)

let () =
  Fmt_tty.setup_std_outputs ();
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  exit (Cmd.eval cmd)
