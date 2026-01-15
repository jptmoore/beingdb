(** Pull updates from remote and merge into Irmin Git *)

open Lwt.Syntax
open Cmdliner

module Store = Irmin_git_unix.FS.KV(Irmin.Contents.String)
module Sync = Irmin.Sync.Make(Store)

let pull_updates git_path remote branch =
  Lwt_main.run (
    let* () = Logs_lwt.info (fun m -> m "BeingDB Pull") in
    let* () = Logs_lwt.info (fun m -> m "Store:  %s" git_path) in
    let* () = Logs_lwt.info (fun m -> m "Remote: %s" remote) in
    let* () = Logs_lwt.info (fun m -> m "Branch: %s" branch) in
    let* () = Logs_lwt.info (fun m -> m "") in
    
    Lwt.catch (fun () ->
      let* () = Logs_lwt.info (fun m -> m "Opening Git store...") in
      let config = Irmin_git.config ~bare:true git_path in
      let* repo = Store.Repo.v config in
      let* store = Store.main repo in
      
      let* () = Logs_lwt.info (fun m -> m "Pulling from remote...") in
      let* remote_ref = Store.remote remote in
      
      (* Pull from remote - fetches and merges into current branch *)
      let* result = Sync.pull store remote_ref `Set in
      
      match result with
      | Ok (`Head _) ->
          let* () = Logs_lwt.info (fun m -> m "Successfully pulled updates") in
          let* () = Logs_lwt.info (fun m -> m "Git store updated at: %s" git_path) in
          Lwt.return_unit
      | Ok `Empty ->
          let* () = Logs_lwt.info (fun m -> m "No updates (remote is empty)") in
          Lwt.return_unit
      | Error (`Msg msg) ->
          let* () = Logs_lwt.err (fun m -> m "Pull failed: %s" msg) in
          Lwt.fail_with msg
      | Error (`Conflict msg) ->
          let* () = Logs_lwt.err (fun m -> m "Conflict during pull: %s" msg) in
          let* () = Logs_lwt.info (fun m -> m "Manual resolution required") in
          Lwt.fail_with msg
    ) (fun exn ->
      let error_msg = Printexc.to_string exn in
      
      (* Detect network/connectivity errors *)
      let is_network_error = 
        String.lowercase_ascii error_msg |> fun msg ->
        List.exists (fun pattern -> 
          try Str.search_forward (Str.regexp_case_fold pattern) msg 0 >= 0 
          with Not_found -> false
        ) ["handshake"; "not found"; "not reachable"; "connection"; "timeout"; "network"]
      in
      
      if is_network_error then
        (* Network/proxy issue *)
        let* () = Logs_lwt.err (fun m -> m "Network connection failed") in
        let* () = Logs_lwt.info (fun m -> m "") in
        let* () = Logs_lwt.info (fun m -> m "Unable to reach remote repository (likely network/proxy issue).") in
        let* () = Logs_lwt.info (fun m -> m "") in
        let* () = Logs_lwt.info (fun m -> m "Solutions:") in
        let* () = Logs_lwt.info (fun m -> m "1. Try from outside corporate network/proxy") in
        let* () = Logs_lwt.info (fun m -> m "2. Try SSH URL instead of HTTPS") in
        let* () = Logs_lwt.info (fun m -> m "3. Use manual workflow:") in
        let* () = Logs_lwt.info (fun m -> m "   cd <repo> && git pull") in
        let* () = Logs_lwt.info (fun m -> m "   beingdb-import --input <repo> --git %s" git_path) in
        Lwt.return_unit
      else
        let* () = Logs_lwt.err (fun m -> m "Pull failed: %s" error_msg) in
        let* () = Logs_lwt.info (fun m -> m "") in
        let* () = Logs_lwt.info (fun m -> m "Troubleshooting:") in
        let* () = Logs_lwt.info (fun m -> m "- Ensure Git store exists at: %s" git_path) in
        let* () = Logs_lwt.info (fun m -> m "- Check network connectivity") in
        let* () = Logs_lwt.info (fun m -> m "- Verify remote URL is correct") in
        Lwt.return_unit
    )
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
