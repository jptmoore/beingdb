(** CLI: `import` -- import flat predicate files into an Irmin Git store
    (development tool). Shared by the standalone [beingdb-import] binary
    and the [beingdb import] subcommand. *)

open Lwt.Syntax
open Cmdliner

let import_predicate git_store path =
  let filename = Filename.basename path in
  let* content_lines = Lwt_io.lines_of_file path |> Lwt_stream.to_list in
  let content = String.concat "\n" content_lines in

  (* Batch write: entire predicate in single commit *)
  let* () = Git_backend.write_predicate git_store filename content in
  Lwt_io.printlf "✓ %s (%d lines)" filename (List.length content_lines)

let import_directory input_dir git_path =
  (* Validate input directory exists before starting *)
  if not (Sys.file_exists input_dir) then (
    Printf.eprintf "import: [ERROR] Input directory does not exist: %s\n%!" input_dir;
    exit 1);

  if not (Sys.is_directory input_dir) then (
    Printf.eprintf "import: [ERROR] Input path is not a directory: %s\n%!" input_dir;
    exit 1);

  Lwt_main.run
    (let* () = Lwt_io.printl "BeingDB Import" in
     let* () = Lwt_io.printlf "Input: %s" input_dir in
     let* () = Lwt_io.printlf "Git:   %s" git_path in
     let* () = Lwt_io.printl "" in

     let* git = Git_backend.init git_path in

     (* Check for predicates/ subdirectory (repo structure convention) *)
     let predicates_dir = Filename.concat input_dir "predicates" in
     let scan_dir = if Sys.file_exists predicates_dir && Sys.is_directory predicates_dir then predicates_dir else input_dir in

     let* () = if scan_dir = predicates_dir then Lwt_io.printl "Using predicates/ subdirectory" else Lwt.return_unit in

     (* Filter predicate files: exclude known non-data file types *)
     let is_predicate_file path =
       let basename = Filename.basename path in
       (* Skip hidden files and directories *)
       if String.starts_with ~prefix:"." basename || Sys.is_directory path then false
         (* Skip README and common documentation files *)
       else if String.starts_with ~prefix:"README" (String.uppercase_ascii basename) then false
         (* Skip by extension: scripts, docs, configs *)
       else if
         String.ends_with ~suffix:".sh" path
         || String.ends_with ~suffix:".md" path
         || String.ends_with ~suffix:".txt" path
         || String.ends_with ~suffix:".json" path
         || String.ends_with ~suffix:".yml" path
         || String.ends_with ~suffix:".yaml" path
       then false
         (* Accept .pl and files without extensions as predicates *)
       else true
     in

     let files = Sys.readdir scan_dir |> Array.to_list |> List.map (Filename.concat scan_dir) |> List.filter is_predicate_file in

     let* () = Lwt_io.printlf "Found %d predicates" (List.length files) in

     if List.length files = 0 then
       let* () = Lwt_io.eprintlf "Warning: No predicates found in %s" scan_dir in
       let* () = Lwt_io.printl "" in
       Lwt_io.printl "Import complete (nothing to import)"
     else
       let* () = Lwt_io.printl "" in

       (* Import each file *)
       let* () = Lwt_list.iter_s (import_predicate git) files in

       let* () = Lwt_io.printl "" in
       Lwt_io.printl "Import complete!")

let input_dir =
  let doc = "Input directory containing flat predicate files" in
  Arg.(value & opt string "./test_data" & info [ "input"; "i" ] ~docv:"DIR" ~doc)

let git_path =
  let doc = "Irmin Git store directory" in
  Arg.(value & opt string "./git-store" & info [ "git"; "g" ] ~docv:"DIR" ~doc)

let cmd =
  let doc = "Import flat predicate files into Irmin Git (development tool)" in
  let man =
    [
      `S Manpage.s_description;
      `P "Imports flat predicate files into Irmin Git store for development/testing.";
      `P "In production, use 'beingdb clone' to clone a remote repository instead.";
      `P "Example:";
      `Pre "  beingdb-import --input ./test_data --git ./git-store";
    ]
  in
  let info = Cmd.info "import" ~version:"0.1.0" ~doc ~man in
  Cmd.v info Term.(const import_directory $ input_dir $ git_path)
