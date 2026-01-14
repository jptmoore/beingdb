(** Clone remote Git repository into Irmin Git store (shallow) *)

open Lwt.Syntax
open Cmdliner

let clone_repo repo_url git_path =
  Lwt_main.run (
    let* () = Logs_lwt.info (fun m -> m "BeingDB Clone") in
    let* () = Logs_lwt.info (fun m -> m "Remote: %s" repo_url) in
    let* () = Logs_lwt.info (fun m -> m "Local:  %s" git_path) in
    let* () = Logs_lwt.info (fun m -> m "") in
    
    (* For now, we'll use a simple approach: initialize Irmin Git and fetch *)
    (* In the future, we can use Irmin's remote sync capabilities *)
    let* () = Logs_lwt.info (fun m -> m "Note: Clone functionality requires Irmin remote sync (TODO)") in
    let* () = Logs_lwt.info (fun m -> m "For now, use: git clone %s && beingdb-import" repo_url) in
    
    Lwt.return_unit
  )

let repo_url =
  let doc = "Remote Git repository URL" in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"REPO_URL" ~doc)

let git_path =
  let doc = "Local Irmin Git store directory" in
  Arg.(value & opt string "./git-store" & info ["git"; "g"] ~docv:"DIR" ~doc)

let cmd =
  let doc = "Clone remote Git repository into Irmin Git (shallow)" in
  let man = [
    `S Manpage.s_description;
    `P "Clones a remote Git repository containing predicates into a local Irmin Git store.";
    `P "Only fetches HEAD (shallow clone) since full history is maintained in Pack snapshots.";
    `P "Example:";
    `Pre "  beingdb clone https://github.com/org/beingdb-facts.git";
  ] in
  let info = Cmd.info "clone" ~version:"0.1.0" ~doc ~man in
  Cmd.v info Term.(const clone_repo $ repo_url $ git_path)

let () =
  Fmt_tty.setup_std_outputs ();
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  exit (Cmd.eval cmd)
