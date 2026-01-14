(** Import flat files into Irmin-git backend *)

open Lwt.Syntax
open Cmdliner

let import_predicate git_store path =
  let filename = Filename.basename path in
  let* content_lines = Lwt_io.lines_of_file path |> Lwt_stream.to_list in
  let content = String.concat "\n" content_lines in
  
  let* () = Logs_lwt.info (fun m -> m "Importing %s (%d lines)" filename (List.length content_lines)) in
  let* () = Beingdb.Git_backend.write_predicate git_store filename content in
  Logs_lwt.info (fun m -> m "✓ Imported %s" filename)

let import_directory input_dir git_path =
  Lwt_main.run (
    let* () = Logs_lwt.info (fun m -> m "BeingDB Import") in
    let* () = Logs_lwt.info (fun m -> m "Input: %s" input_dir) in
    let* () = Logs_lwt.info (fun m -> m "Git:   %s" git_path) in
    let* () = Logs_lwt.info (fun m -> m "") in
    
    let* git = Beingdb.Git_backend.init git_path in
    
    (* Find all files in source directory *)
    let files = Sys.readdir input_dir 
                |> Array.to_list
                |> List.filter (fun f -> 
                    not (String.starts_with ~prefix:"." f))
                |> List.map (Filename.concat input_dir)
                |> List.filter (fun p -> not (Sys.is_directory p))
    in
    
    let* () = Logs_lwt.info (fun m -> m "Found %d predicate files" (List.length files)) in
    let* () = Logs_lwt.info (fun m -> m "") in
    
    (* Import each file *)
    let* () = Lwt_list.iter_s (import_predicate git) files in
    
    let* () = Logs_lwt.info (fun m -> m "") in
    Logs_lwt.info (fun m -> m "Import complete!")
  )

let input_dir =
  let doc = "Input directory containing flat predicate files" in
  Arg.(value & opt string "./test_data" & info ["input"; "i"] ~docv:"DIR" ~doc)

let git_path =
  let doc = "Irmin Git store directory" in
  Arg.(value & opt string "./git-store" & info ["git"; "g"] ~docv:"DIR" ~doc)

let cmd =
  let doc = "Import flat predicate files into Irmin Git (development tool)" in
  let man = [
    `S Manpage.s_description;
    `P "Imports flat predicate files into Irmin Git store for development/testing.";
    `P "In production, use 'beingdb clone' to clone a remote repository instead.";
    `P "Example:";
    `Pre "  beingdb-import --input ./test_data --git ./git-store";
  ] in
  let info = Cmd.info "import" ~version:"0.1.0" ~doc ~man in
  Cmd.v info Term.(const import_directory $ input_dir $ git_path)

let () =
  Fmt_tty.setup_std_outputs ();
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  exit (Cmd.eval cmd)
