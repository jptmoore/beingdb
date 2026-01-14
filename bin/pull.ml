(** Pull updates from remote and merge into Irmin Git *)

open Lwt.Syntax
open Cmdliner

let pull_updates git_path remote branch =
  Lwt_main.run (
    let* () = Logs_lwt.info (fun m -> m "BeingDB Pull") in
    let* () = Logs_lwt.info (fun m -> m "Store:  %s" git_path) in
    let* () = Logs_lwt.info (fun m -> m "Remote: %s" remote) in
    let* () = Logs_lwt.info (fun m -> m "Branch: %s" branch) in
    let* () = Logs_lwt.info (fun m -> m "") in
    
    (* For now, we'll use a simple approach *)
    (* In the future, we can use Irmin's remote sync and merge capabilities *)
    let* () = Logs_lwt.info (fun m -> m "Note: Pull functionality requires Irmin remote sync (TODO)") in
    let* () = Logs_lwt.info (fun m -> m "For now, use: git pull && beingdb-import") in
    
    Lwt.return_unit
  )

let git_path =
  let doc = "Local Irmin Git store directory" in
  Arg.(value & opt string "./git-store" & info ["git"; "g"] ~docv:"DIR" ~doc)

let remote =
  let doc = "Remote name" in
  Arg.(value & opt string "origin" & info ["remote"; "r"] ~docv:"REMOTE" ~doc)

let branch =
  let doc = "Branch name" in
  Arg.(value & opt string "main" & info ["branch"; "b"] ~docv:"BRANCH" ~doc)

let cmd =
  let doc = "Pull updates from remote and merge into Irmin Git" in
  let man = [
    `S Manpage.s_description;
    `P "Fetches updates from the remote repository and merges them into the local Irmin Git store.";
    `P "Handles conflict resolution using Irmin's merge capabilities.";
    `P "Example:";
    `Pre "  beingdb pull";
    `Pre "  beingdb pull --remote upstream --branch develop";
  ] in
  let info = Cmd.info "pull" ~version:"0.1.0" ~doc ~man in
  Cmd.v info Term.(const pull_updates $ git_path $ remote $ branch)

let () =
  Fmt_tty.setup_std_outputs ();
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  exit (Cmd.eval cmd)
