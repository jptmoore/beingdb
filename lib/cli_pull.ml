(** CLI: `pull` -- pull updates from remote and merge into an Irmin Git
    store. Shared by the standalone [beingdb-pull] binary and the
    [beingdb pull] subcommand. *)

open Lwt.Syntax
open Cmdliner

module Store = Irmin_git_unix.FS.KV (Irmin.Contents.String)
module Sync = Irmin.Sync.Make (Store)

let pull_updates git_path remote_url branch =
  Mirage_crypto_rng_unix.use_default ();
  Lwt_main.run
    (let* () = Lwt_io.printl "BeingDB Pull" in
     let* () = Lwt_io.printlf "Store:  %s" git_path in
     let* () = Lwt_io.printlf "Remote: %s" remote_url in
     let* () = Lwt_io.printlf "Branch: %s" branch in
     let* () = Lwt_io.printl "" in

     Lwt.catch
       (fun () ->
         let* () = Lwt_io.printl "Opening Git store..." in
         let config = Irmin_git.config ~bare:true git_path in
         let* repo = Store.Repo.v config in
         let* store = Store.of_branch repo branch in

         let* () = Lwt_io.printl "Pulling from remote..." in
         let* remote_ref = Store.remote remote_url in

         (* Pull from remote - fetches and merges into current branch *)
         let* result = Sync.pull store remote_ref `Set in

         match result with
         | Ok (`Head _) ->
             let* () = Lwt_io.printl "Successfully pulled updates" in
             let* () = Lwt_io.printlf "Git store updated at: %s" git_path in
             Lwt.return_unit
         | Ok `Empty ->
             let* () = Lwt_io.printl "No updates (remote is empty)" in
             Lwt.return_unit
         | Error (`Msg msg) ->
             let* () = Lwt_io.eprintlf "Pull failed: %s" msg in
             Lwt.fail_with msg
         | Error (`Conflict msg) ->
             let* () = Lwt_io.eprintlf "Conflict during pull: %s" msg in
             let* () = Lwt_io.eprintl "Manual resolution required" in
             Lwt.fail_with msg)
       (fun exn ->
         let error_msg = Printexc.to_string exn in

         let is_repo_not_found =
           try Str.search_forward (Str.regexp_case_fold "repository not found") (String.lowercase_ascii error_msg) 0 >= 0
           with Not_found -> false
         in

         (* Detect network/connectivity errors *)
         let is_network_error =
           String.lowercase_ascii error_msg |> fun msg ->
           List.exists
             (fun pattern ->
               try Str.search_forward (Str.regexp_case_fold pattern) msg 0 >= 0 with Not_found -> false)
             [ "handshake"; "could not resolve"; "not reachable"; "connection"; "timeout"; "network" ]
         in

         if is_repo_not_found then
           (* Wrong URL, or repo is private/missing -- not a network problem *)
           let* () = Lwt_io.eprintl "Repository not found" in
           let* () = Lwt_io.eprintl "" in
           let* () = Lwt_io.eprintlf "GitHub reports no repository at: %s" remote_url in
           let* () = Lwt_io.eprintl "" in
           let* () = Lwt_io.eprintl "Check:" in
           let* () = Lwt_io.eprintl "1. The URL is correct (organization/user and repo name)" in
           let* () = Lwt_io.eprintl "2. For private repos, use a token: https://TOKEN@github.com/user/repo.git" in
           Lwt.return_unit
         else if is_network_error then
           (* Network/proxy issue *)
           let* () = Lwt_io.eprintl "Network connection failed" in
           let* () = Lwt_io.eprintl "" in
           let* () = Lwt_io.eprintl "Unable to reach remote repository (likely network/proxy issue)." in
           let* () = Lwt_io.eprintl "" in
           let* () = Lwt_io.eprintl "Solutions:" in
           let* () = Lwt_io.eprintl "1. Try from outside corporate network/proxy" in
           let* () = Lwt_io.eprintl "2. Try SSH URL instead of HTTPS" in
           let* () = Lwt_io.eprintl "3. Use manual workflow:" in
           let* () = Lwt_io.eprintl "   cd <repo> && git pull" in
           let* () = Lwt_io.eprintlf "   beingdb-import --input <repo> --git %s" git_path in
           Lwt.return_unit
         else
           let* () = Lwt_io.eprintlf "Pull failed: %s" error_msg in
           let* () = Lwt_io.eprintl "" in
           let* () = Lwt_io.eprintl "Troubleshooting:" in
           let* () = Lwt_io.eprintlf "- Ensure Git store exists at: %s" git_path in
           let* () = Lwt_io.eprintl "- Check network connectivity" in
           let* () = Lwt_io.eprintl "- Verify remote URL is correct" in
           Lwt.return_unit))

let git_path =
  let doc = "Local Irmin Git store directory" in
  Arg.(value & opt string "./git_store" & info [ "git"; "g" ] ~docv:"DIR" ~doc)

let remote =
  let doc =
    "Remote Git repository URL to pull from (Irmin has no notion of named remotes like 'origin' -- the actual \
     URL must be given every time, as with clone)"
  in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"REPO_URL" ~doc)

let branch =
  let doc = "Branch name" in
  Arg.(value & opt string "main" & info [ "branch"; "b" ] ~docv:"BRANCH" ~doc)

let cmd =
  let doc = "Pull updates from remote and merge into Irmin Git" in
  let man =
    [
      `S Manpage.s_description;
      `P "Fetches updates from the remote repository and merges them into the local Irmin Git store.";
      `P "Handles conflict resolution using Irmin's merge capabilities.";
      `P "Example:";
      `Pre "  beingdb pull https://github.com/your-org/your-facts.git";
      `Pre "  beingdb pull https://github.com/your-org/your-facts.git --branch develop";
    ]
  in
  let info = Cmd.info "pull" ~version:Version.version ~doc ~man in
  Cmd.v info Term.(const pull_updates $ git_path $ remote $ branch)
