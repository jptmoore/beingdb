(** CLI: `repl` -- interactive queries against a Pack store, plus utility
    commands to load facts or batches of queries from a file. Shared by
    the standalone [beingdb-repl] binary and the [beingdb repl]
    subcommand.

    Unlike the read-only HTTP server, [:load]-ing a facts file writes
    directly into the open Pack store -- a deliberate, local-only
    convenience for experimentation, distinct from the Git-first compile
    workflow. *)

open Cmdliner

type mode = Core | Dsl | Auto

let mode_name = function Core -> "core" | Dsl -> "dsl" | Auto -> "auto"

let print_help () =
  print_string
    (String.concat "\n"
       [
         "Commands:";
         "  <query>              run a query in the current language mode";
         "                       (in :dsl/:auto-detected-dsl mode, keep entering lines,";
         "                        a blank line finishes the query)";
         "  :predicates          list predicates and arities";
         "  :describe <name>     show a predicate's argument types, fact count, and examples";
         "  :environment         show predicate count, fingerprint, language version, and mode";
         "  :explain <query>     show the query plan without executing it (single-line only)";
         "  :validate            enter a query (blank line to finish) and validate it without executing";
         "  :core                switch to the core predicate-pattern query language";
         "  :dsl                 switch to the expressive (find/where/...) query language";
         "  :auto                auto-detect the language per query (\"find ...\" => dsl, else core)";
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

let describe_predicate store name =
  let env = Lwt_main.run (Query_environment.load_or_build store) in
  match Query_environment.find env name with
  | None -> Printf.printf "Unknown predicate: %s\n" name
  | Some p ->
      Printf.printf "%s/%d  (%d facts)\n" p.Query_environment.name p.Query_environment.arity p.Query_environment.count;
      List.iter
        (fun (a : Query_environment.argument_signature) ->
          Printf.printf "  arg %d: %s\n" a.position (String.concat " | " a.types))
        p.Query_environment.arguments;
      if p.Query_environment.examples <> [] then (
        print_endline "  examples:";
        List.iter
          (fun args -> Printf.printf "    %s(%s)\n" name (String.concat ", " (List.map Value.canonical_string args)))
          p.Query_environment.examples)

let show_environment store mode =
  let env = Lwt_main.run (Query_environment.load_or_build store) in
  Printf.printf "predicates: %d\n" (List.length env.Query_environment.predicates);
  Printf.printf "environment_fingerprint: %s\n" env.Query_environment.fingerprint;
  Printf.printf "language_version: %s\n" env.Query_environment.language_version;
  Printf.printf "mode: %s\n" (mode_name !mode)

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

(** Print the outcome of {!Controller.run_query}: both [Success] and
    [Invalid] carry well-formed JSON (the latter is a structured
    validation failure, not a hard error), only [Failure] is a plain
    error message. *)
let print_outcome = function
  | Controller.Success json | Controller.Invalid json -> print_endline (Yojson.Safe.pretty_to_string json)
  | Controller.Failure { code; message } -> Printf.printf "Error [%s]: %s\n" code message

let run_query_language ~language ~action store limit query_text =
  print_outcome (Lwt_main.run (Controller.run_query ~max_results:limit ~language ~action store query_text ~offset:None ~limit:None))

(** Does the query text look like the expressive language's surface
    syntax (starts with the [find] keyword)? Used by [:auto] mode. *)
let looks_like_dsl text =
  let trimmed = String.trim text in
  String.length trimmed >= 4
  && String.lowercase_ascii (String.sub trimmed 0 4) = "find"
  && (String.length trimmed = 4 || trimmed.[4] = ' ' || trimmed.[4] = '\t')

let strip_prefix prefix line = String.sub line (String.length prefix) (String.length line - String.length prefix)

let dispatch ~read_block store limit mode line =
  match line with
  | "" -> ()
  | ":quit" | ":exit" -> ()
  | ":help" -> print_help ()
  | ":predicates" -> show_predicates store
  | ":environment" -> show_environment store mode
  | ":core" ->
      mode := Core;
      print_endline "mode: core"
  | ":dsl" ->
      mode := Dsl;
      print_endline "mode: dsl"
  | ":auto" ->
      mode := Auto;
      print_endline "mode: auto"
  | ":validate" ->
      let lines = read_block "...> " in
      let text = String.concat "\n" lines in
      if String.trim text = "" then ()
      else
        let language = match !mode with Core -> "core" | Dsl -> "dsl" | Auto -> if looks_like_dsl text then "dsl" else "core" in
        run_query_language ~language ~action:"validate" store !limit text
  | _ when String.starts_with ~prefix:":describe " line -> describe_predicate store (String.trim (strip_prefix ":describe " line))
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
  | query -> (
      match !mode with
      | Core -> run_query_language ~language:"core" ~action:"execute" store !limit query
      | Dsl ->
          let rest = read_block "...> " in
          run_query_language ~language:"dsl" ~action:"execute" store !limit (String.concat "\n" (query :: rest))
      | Auto ->
          if looks_like_dsl query then
            let rest = read_block "...> " in
            run_query_language ~language:"dsl" ~action:"execute" store !limit (String.concat "\n" (query :: rest))
          else run_query_language ~language:"core" ~action:"execute" store !limit query)

let run_repl pack_path default_limit history_file =
  let store = Lwt_main.run (Pack_backend.init ~fresh:false pack_path) in
  let limit = ref default_limit in
  let mode = ref Auto in
  ignore (LNoise.history_set ~max_length:500);
  ignore (LNoise.history_load ~filename:history_file);
  LNoise.set_multiline true;
  let read_block prompt =
    let rec go acc =
      match LNoise.linenoise prompt with
      | None -> List.rev acc
      | Some raw ->
          let l = String.trim raw in
          if l <> "" then ignore (LNoise.history_add l);
          if l = "" then List.rev acc else go (l :: acc)
    in
    go []
  in
  let env = Lwt_main.run (Query_environment.load_or_build store) in
  Printf.printf "BeingDB REPL. %d predicates, fingerprint %s, %s, mode %s. Type :help for commands, :quit to exit.\n"
    (List.length env.Query_environment.predicates) env.Query_environment.fingerprint env.Query_environment.language_version
    (mode_name !mode);
  let continue = ref true in
  while !continue do
    match LNoise.linenoise "beingdb> " with
    | None -> continue := false
    | Some raw_line ->
        let line = String.trim raw_line in
        if line <> "" then ignore (LNoise.history_add line);
        if line = ":quit" || line = ":exit" then continue := false
        else (
          dispatch ~read_block store limit mode line;
          flush stdout)
  done;
  ignore (LNoise.history_save ~filename:history_file);
  print_endline "Goodbye."

let default_history_path =
  match Sys.getenv_opt "HOME" with Some home -> Filename.concat home ".beingdb_history" | None -> ".beingdb_history"

let pack_arg =
  let doc = "Pack store directory to open (read for queries; written to only via :load on a facts file)" in
  Arg.(value & opt string "./pack_store" & info [ "pack"; "p" ] ~docv:"DIR" ~doc)

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
  let info = Cmd.info "repl" ~version:Version.version ~doc ~man in
  Cmd.v info Term.(const run_repl $ pack_arg $ limit_arg $ history_arg)
