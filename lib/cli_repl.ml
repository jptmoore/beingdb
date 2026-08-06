(** CLI: `repl` -- interactive queries against a Pack store, plus utility
    commands to load facts or batches of queries from a file. Shared by
    the standalone [beingdb-repl] binary and the [beingdb repl]
    subcommand.

    Unlike the read-only HTTP server, [:load]-ing a facts file writes
    directly into the open Pack store -- a deliberate, local-only
    convenience for experimentation, distinct from the Git-first compile
    workflow. *)

open Cmdliner

let print_help () =
  print_string
    (String.concat "\n"
       [
         "Commands:";
         "  <query>              run a query, e.g. created(Artist, Work)";
         "  :predicates          list predicates and arities";
         "  :explain <query>     show the query plan without executing it";
         "  :load <file>         load facts (.pl/.pro/.facts) or run queries (any other extension)";
         "  :loadfacts <file>    force-load a file as facts, written into the pack store";
         "  :loadqueries <file>  force-run every line of a file as a query";
         "  :limit <n>           set the default max rows shown per query";
         "  :help                show this message";
         "  :quit / :exit        leave the REPL";
         "";
       ])

let show_predicates store =
  let open Lwt.Infix in
  Lwt_main.run (Db.list_predicates store >|= fun predicates -> predicates)
  |> List.iter (fun (name, arity) -> Printf.printf "  %s/%d\n" name arity)

let explain_query text =
  match Query_parser.parse_query_result text with
  | Error e -> Printf.printf "Parse error: %s\n" e
  | Ok query -> print_endline (Query_engine.explain query)

let set_limit limit text =
  match int_of_string_opt (String.trim text) with
  | Some n when n > 0 ->
      limit := n;
      Printf.printf "limit set to %d\n" n
  | _ -> Printf.printf "Invalid limit: %s\n" text

let load_facts store file =
  match Lwt_main.run (Repl_support.load_facts_file store file) with
  | Ok summaries -> List.iter (Printf.printf "  %s\n") summaries
  | Error e -> Printf.printf "Error: %s\n" e

let load_queries store limit file =
  Lwt_main.run (Repl_support.run_queries_file ~max_results:limit store file)
  |> List.iter (fun (query_text, result) ->
         Printf.printf "> %s\n" query_text;
         match result with
         | Ok json -> print_endline (Yojson.Safe.pretty_to_string json)
         | Error e -> Printf.printf "Error: %s\n" e)

let run_query store limit query_text =
  match Lwt_main.run (Controller.execute_query ~max_results:limit store query_text ~offset:None ~limit:None) with
  | Ok json -> print_endline (Yojson.Safe.pretty_to_string json)
  | Error e -> Printf.printf "Error: %s\n" e

let strip_prefix prefix line = String.sub line (String.length prefix) (String.length line - String.length prefix)

let dispatch store limit line =
  match line with
  | "" -> ()
  | ":quit" | ":exit" -> ()
  | ":help" -> print_help ()
  | ":predicates" -> show_predicates store
  | _ when String.starts_with ~prefix:":explain " line -> explain_query (strip_prefix ":explain " line)
  | _ when String.starts_with ~prefix:":limit " line -> set_limit limit (strip_prefix ":limit " line)
  | _ when String.starts_with ~prefix:":loadfacts " line -> load_facts store (strip_prefix ":loadfacts " line)
  | _ when String.starts_with ~prefix:":loadqueries " line -> load_queries store !limit (strip_prefix ":loadqueries " line)
  | _ when String.starts_with ~prefix:":load " line -> (
      let file = strip_prefix ":load " line in
      match Repl_support.load_kind_of_filename file with
      | Facts -> load_facts store file
      | Queries -> load_queries store !limit file)
  | _ when String.starts_with ~prefix:":" line -> Printf.printf "Unknown command: %s (try :help)\n" line
  | query -> run_query store !limit query

let run_repl pack_path default_limit history_file =
  let store = Lwt_main.run (Pack_backend.init ~fresh:false pack_path) in
  let limit = ref default_limit in
  ignore (LNoise.history_set ~max_length:500);
  ignore (LNoise.history_load ~filename:history_file);
  LNoise.set_multiline true;
  print_endline "BeingDB REPL. Type :help for commands, :quit to exit.";
  let continue = ref true in
  while !continue do
    match LNoise.linenoise "beingdb> " with
    | None -> continue := false
    | Some raw_line ->
        let line = String.trim raw_line in
        if line <> "" then ignore (LNoise.history_add line);
        if line = ":quit" || line = ":exit" then continue := false
        else (
          dispatch store limit line;
          flush stdout)
  done;
  ignore (LNoise.history_save ~filename:history_file);
  print_endline "Goodbye."

let default_history_path =
  match Sys.getenv_opt "HOME" with Some home -> Filename.concat home ".beingdb_history" | None -> ".beingdb_history"

let pack_arg =
  let doc = "Pack store directory to open (read for queries; written to only via :load on a facts file)" in
  Arg.(required & opt (some string) None & info [ "pack"; "p" ] ~docv:"DIR" ~doc)

let limit_arg =
  let doc = "Default maximum rows returned per query (override interactively with :limit N)" in
  Arg.(value & opt int 1000 & info [ "limit"; "l" ] ~docv:"N" ~doc)

let history_arg =
  let doc = "History file for line editing" in
  Arg.(value & opt string default_history_path & info [ "history" ] ~docv:"FILE" ~doc)

let cmd =
  let doc = "Interactive REPL: run queries against a Pack store, or load facts/queries from a file" in
  let man =
    [
      `S Manpage.s_description;
      `P "Opens the given Pack store and reads queries from the terminal, one per line, printing typed JSON results.";
      `P
        "Meta-commands (all start with ':'): :help, :predicates, :explain <query>, :load <file>, :loadfacts \
         <file>, :loadqueries <file>, :limit <n>, :quit.";
      `P "Example:";
      `Pre "  beingdb repl --pack ./pack_store";
      `Pre "  beingdb-repl --pack ./pack_store";
    ]
  in
  let info = Cmd.info "repl" ~version:"0.1.0" ~doc ~man in
  Cmd.v info Term.(const run_repl $ pack_arg $ limit_arg $ history_arg)
