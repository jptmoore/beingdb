(** Unit tests for Repl_support: file-extension load-kind detection, and
    loading facts / running queries from a file against a scratch pack
    store. *)

open Lwt.Syntax
open Beingdb

let create_test_pack name =
  let test_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "beingdb_repl_test_%s_%d_%d" name (Unix.getpid ()) (Random.bits ()))
  in
  (try Unix.rmdir test_dir with _ -> ());
  Unix.mkdir test_dir 0o755;
  test_dir

let cleanup path = ignore (Unix.system (Printf.sprintf "rm -rf %s" (Filename.quote path)))

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc

let with_store f =
  let test_dir = create_test_pack "store" in
  Lwt_main.run
    (let* store = Pack_backend.init ~fresh:true test_dir in
     let* () = f store in
     cleanup test_dir;
     Lwt.return_unit)

(* --- load_kind_of_filename --- *)

let test_load_kind_facts () =
  Alcotest.(check bool) ".pl is facts" true (Repl_support.load_kind_of_filename "created.pl" = Repl_support.Facts);
  Alcotest.(check bool) ".pro is facts" true (Repl_support.load_kind_of_filename "foo.pro" = Repl_support.Facts);
  Alcotest.(check bool) ".facts is facts" true (Repl_support.load_kind_of_filename "bar.facts" = Repl_support.Facts);
  Alcotest.(check bool) "uppercase extension" true (Repl_support.load_kind_of_filename "BAR.PL" = Repl_support.Facts)

let test_load_kind_queries () =
  Alcotest.(check bool) ".ql is queries" true (Repl_support.load_kind_of_filename "queries.ql" = Repl_support.Queries);
  Alcotest.(check bool) "no extension is queries" true (Repl_support.load_kind_of_filename "queries" = Repl_support.Queries);
  Alcotest.(check bool) ".txt is queries" true (Repl_support.load_kind_of_filename "notes.txt" = Repl_support.Queries)

(* --- load_facts_file --- *)

let test_load_facts_file_writes_store () =
  with_store (fun store ->
      let dir = create_test_pack "facts_file" in
      let path = Filename.concat dir "created.pl" in
      write_file path "created(tina_keane, she).\ncreated(tina_keane, faded_wallpaper).\n";
      let* result = Repl_support.load_facts_file store path in
      (match result with
      | Ok summaries -> Alcotest.(check bool) "one summary line" true (List.length summaries = 1)
      | Error e -> Alcotest.fail e);
      let* facts = Pack_backend.query_all store "created" in
      Alcotest.(check int) "two facts written" 2 (List.length facts);
      cleanup dir;
      Lwt.return_unit)

let test_load_facts_file_reports_parse_errors () =
  with_store (fun store ->
      let dir = create_test_pack "facts_errors" in
      let path = Filename.concat dir "bad.pl" in
      write_file path "created(tina_keane, she).\nnot_closed(\n";
      let* result = Repl_support.load_facts_file store path in
      (match result with
      | Ok summaries ->
          Alcotest.(check bool) "has a parse-error entry"
            true
            (List.exists (fun s -> String.length s > 0 && s <> "created (1 facts)") summaries)
      | Error e -> Alcotest.fail e);
      cleanup dir;
      Lwt.return_unit)

let test_load_facts_file_arity_mismatch () =
  with_store (fun store ->
      let dir = create_test_pack "facts_arity" in
      let path = Filename.concat dir "mixed.pl" in
      write_file path "created(a, b).\ncreated(a, b, c).\n";
      let* result = Repl_support.load_facts_file store path in
      (match result with
      | Ok summaries ->
          Alcotest.(check bool) "arity mismatch reported" true
            (List.mem "created: arity mismatch, not written" summaries)
      | Error e -> Alcotest.fail e);
      let* facts = Pack_backend.query_all store "created" in
      Alcotest.(check int) "nothing written" 0 (List.length facts);
      cleanup dir;
      Lwt.return_unit)

let test_load_facts_file_missing () =
  with_store (fun store ->
      let* result = Repl_support.load_facts_file store "/nonexistent/path/x.pl" in
      Alcotest.(check bool) "reports an error" true (Result.is_error result);
      Lwt.return_unit)

(* --- run_queries_file --- *)

let test_run_queries_file () =
  with_store (fun store ->
      let* () =
        Pack_backend.write_predicate_batch store "created"
          [ Fact.make "created" [ Value.Atom "tina_keane"; Value.Atom "she" ] ]
          "seed"
      in
      let dir = create_test_pack "queries_file" in
      let path = Filename.concat dir "queries.ql" in
      write_file path "% a comment\ncreated(Artist, Work)\ncreated(tina_keane, nobody)\n";
      let* results = Repl_support.run_queries_file ~max_results:100 store path in
      Alcotest.(check int) "two queries run (comment skipped)" 2 (List.length results);
      (match results with
      | [ (_, Ok first_json); (_, Ok second_json) ] ->
          let count j = Yojson.Safe.Util.member "count" j |> Yojson.Safe.Util.to_int in
          Alcotest.(check int) "first query has a match" 1 (count first_json);
          Alcotest.(check int) "second query has no match" 0 (count second_json)
      | _ -> Alcotest.fail "expected two Ok results");
      cleanup dir;
      Lwt.return_unit)

let () =
  Alcotest.run "BeingDB Repl_support"
    [
      ( "load_kind_of_filename",
        [
          Alcotest.test_case "facts extensions" `Quick test_load_kind_facts;
          Alcotest.test_case "query fallback" `Quick test_load_kind_queries;
        ] );
      ( "load_facts_file",
        [
          Alcotest.test_case "writes facts to store" `Quick test_load_facts_file_writes_store;
          Alcotest.test_case "reports parse errors" `Quick test_load_facts_file_reports_parse_errors;
          Alcotest.test_case "arity mismatch not written" `Quick test_load_facts_file_arity_mismatch;
          Alcotest.test_case "missing file" `Quick test_load_facts_file_missing;
        ] );
      ("run_queries_file", [ Alcotest.test_case "runs each line as a query" `Quick test_run_queries_file ]);
    ]
