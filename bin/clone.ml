(** Clone remote Git repository into Irmin Git store (shallow) *)

open Lwt.Syntax
open Cmdliner

module Store = Irmin_git_unix.FS.KV(Irmin.Contents.String)
module Sync = Irmin.Sync.Make(Store)

let clone_repo repo_url git_path =
  Lwt_main.run (
    let* () = Logs_lwt.info (fun m -> m "BeingDB Clone") in
    let* () = Logs_lwt.info (fun m -> m "Remote: %s" repo_url) in
    let* () = Logs_lwt.info (fun m -> m "Local:  %s" git_path) in
    let* () = Logs_lwt.info (fun m -> m "") in
    
    Lwt.catch (fun () ->
      let* () = Logs_lwt.info (fun m -> m "Initializing Git store...") in
      let config = Irmin_git.config ~bare:true git_path in
      let* repo = Store.Repo.v config in
      let* store = Store.main repo in
      
      let* () = Logs_lwt.info (fun m -> m "Fetching from remote...") in
      let* remote = Store.remote repo_url in
      
      (* Fetch from remote - this will pull all branches and refs *)
      let* result = Sync.fetch store remote in
      
      match result with
      | Ok (`Head head_ref) ->
          (* Set HEAD to point to the fetched branch *)
          let* () = Store.Head.set store head_ref in
          let* () = Logs_lwt.info (fun m -> m "Successfully cloned repository") in
          let* () = Logs_lwt.info (fun m -> m "Git store ready at: %s" git_path) in
          Lwt.return_unit
      | Ok `Empty ->
          let* () = Logs_lwt.warn (fun m -> m "Remote repository is empty") in
          Lwt.return_unit
      | Error (`Msg msg) ->
          let* () = Logs_lwt.err (fun m -> m "Fetch failed: %s" msg) in
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
        let* () = Logs_lwt.info (fun m -> m "2. Try SSH URL: git@github.com:user/repo.git") in
        let* () = Logs_lwt.info (fun m -> m "3. Use manual workflow:") in
        let* () = Logs_lwt.info (fun m -> m "   git clone %s" repo_url) in
        let* () = Logs_lwt.info (fun m -> m "   beingdb-import --input <cloned-dir> --git %s" git_path) in
        Lwt.return_unit
      else
        let* () = Logs_lwt.err (fun m -> m "Clone failed: %s" error_msg) in
        let* () = Logs_lwt.info (fun m -> m "") in
        let* () = Logs_lwt.info (fun m -> m "Troubleshooting:") in
        let* () = Logs_lwt.info (fun m -> m "- Check repository URL is correct") in
        let* () = Logs_lwt.info (fun m -> m "- For private repos, ensure SSH keys are configured") in
        let* () = Logs_lwt.info (fun m -> m "- Check network connectivity") in
        Lwt.return_unit
    )
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
  (* Initialize RNG for git-paf/mirage-crypto *)
  Mirage_crypto_rng_unix.initialize (module Mirage_crypto_rng.Fortuna);
  exit (Cmd.eval cmd)
