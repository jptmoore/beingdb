(** Unit tests for the DB layer: predicate introspection and the typed
    query language (parsing, planning, execution, comparisons, joins). *)

open Lwt.Syntax
open Beingdb

let create_test_pack name =
  let test_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "beingdb_db_test_%s_%d_%d" name (Unix.getpid ()) (Random.bits ()))
  in
  (try Unix.rmdir test_dir with _ -> ());
  Unix.mkdir test_dir 0o755;
  test_dir

let cleanup test_dir =
  let _ = Unix.system (Printf.sprintf "rm -rf %s" (Filename.quote test_dir)) in
  ()

let mkdate y m d = match Value.make_date ~year:y ~month:m ~day:d with Ok v -> v | Error e -> failwith e
let mkinstant s = match Calendar.parse_instant s with Ok t -> Value.Instant t | Error e -> failwith e

(** Sample dataset shared across query-language tests. *)
let sample_facts =
  [
    Fact.make "created" [ Value.Atom "tina_keane"; Value.Atom "she" ];
    Fact.make "created" [ Value.Atom "lynn_hershman"; Value.Atom "lorna" ];
    Fact.make "shown_in" [ Value.Atom "she"; Value.Atom "rewind_1995" ];
    Fact.make "artist" [ Value.Atom "tina_keane" ];
    Fact.make "artist" [ Value.Atom "lynn_hershman" ];
    Fact.make "birth_year" [ Value.Atom "tina_keane"; Value.Year 1951 ];
    Fact.make "birth_year" [ Value.Atom "lynn_hershman"; Value.Year 1941 ];
    Fact.make "confidence" [ Value.Atom "assertion_1"; Value.Decimal (Decimal.make 92L 2) ];
    Fact.make "confidence" [ Value.Atom "assertion_2"; Value.Decimal (Decimal.make 50L 2) ];
    Fact.make "captured_at" [ Value.Atom "capture_1"; mkinstant "2022-08-17T12:30:00Z" ];
    Fact.make "captured_at" [ Value.Atom "capture_2"; mkinstant "2023-01-01T00:00:00Z" ];
    Fact.make "opened" [ Value.Atom "exhibition_1"; mkdate 2019 6 15 ];
    Fact.make "opened" [ Value.Atom "exhibition_2"; mkdate 2020 1 1 ];
  ]

let with_pack name f =
  let test_dir = create_test_pack name in
  Lwt_main.run
    (let* store = Pack_backend.init ~fresh:true test_dir in
     let by_predicate = Hashtbl.create 8 in
     List.iter
       (fun (fact : Fact.t) ->
         let existing = try Hashtbl.find by_predicate fact.predicate with Not_found -> [] in
         Hashtbl.replace by_predicate fact.predicate (fact :: existing))
       sample_facts;
     let* () =
       Lwt_list.iter_s
         (fun predicate ->
           let fs = List.rev (Hashtbl.find by_predicate predicate) in
           Pack_backend.write_predicate_batch store predicate fs (Printf.sprintf "compile %s" predicate))
         (Hashtbl.fold (fun k _ acc -> k :: acc) by_predicate [])
     in
     let* () = f store in
     cleanup test_dir;
     Lwt.return_unit)

let parse_query_exn s =
  match Query_parser.parse_query_result s with Ok q -> q | Error e -> Alcotest.failf "parse error: %s (%s)" e s

let binding_value bindings var =
  match List.assoc_opt var bindings with Some v -> v | None -> Alcotest.failf "unbound variable %s" var

let contains_substring haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
    go 0

(* --- predicate introspection (unchanged behaviour, new types) --- *)

let test_list_predicates () =
  with_pack "list_predicates" (fun store ->
      let* predicates = Db.list_predicates store in
      Alcotest.(check bool) "has predicates" true (List.length predicates >= 3);
      let has_created = List.exists (fun (name, arity) -> name = "created" && arity = 2) predicates in
      let has_artist = List.exists (fun (name, arity) -> name = "artist" && arity = 1) predicates in
      Alcotest.(check bool) "has created/2" true has_created;
      Alcotest.(check bool) "has artist/1" true has_artist;
      Lwt.return_unit)

let test_list_predicates_with_samples () =
  with_pack "list_samples" (fun store ->
      let* predicates = Db.list_predicates_with_samples ~samples:5 store in
      let has_samples =
        List.exists (fun (_, _, samples_opt) -> match samples_opt with Some s -> s <> [] | None -> false) predicates
      in
      Alcotest.(check bool) "at least one predicate has samples" true has_samples;
      Lwt.return_unit)

let test_query_predicate () =
  with_pack "query_pred" (fun store ->
      let* results = Db.query_predicate ~limit:100 store "created" in
      Alcotest.(check int) "has 2 created facts" 2 (List.length results);
      Lwt.return_unit)

let test_query_predicate_limit () =
  with_pack "query_limit" (fun store ->
      let* results = Db.query_predicate ~limit:1 store "artist" in
      Alcotest.(check bool) "respects limit" true (List.length results <= 1);
      Lwt.return_unit)

let test_predicate_exists_true () =
  with_pack "pred_exists" (fun store ->
      let* exists = Db.predicate_exists store "created" in
      Alcotest.(check bool) "created exists" true exists;
      Lwt.return_unit)

let test_predicate_exists_false () =
  with_pack "pred_not_exists" (fun store ->
      let* exists = Db.predicate_exists store "nonexistent" in
      Alcotest.(check bool) "nonexistent doesn't exist" false exists;
      Lwt.return_unit)

(* --- existing pattern queries --- *)

let test_execute_simple_pattern_query () =
  with_pack "execute_query" (fun store ->
      let query = parse_query_exn "created(Artist, Work)" in
      let* result = Db.execute_query store query in
      match result with
      | Ok r ->
          Alcotest.(check int) "two results" 2 (List.length r.Query_engine.bindings);
          Alcotest.(check (list string)) "variables" [ "Artist"; "Work" ] r.Query_engine.variables;
          Lwt.return_unit
      | Error e -> Alcotest.fail e)

let test_execute_query_streaming () =
  with_pack "streaming" (fun store ->
      let query = parse_query_exn "created(Artist, Work), shown_in(Work, Event)" in
      let* result = Db.execute_query_streaming store query ~offset:0 ~limit:1 in
      match result with
      | Ok r -> Alcotest.(check bool) "respects limit" true (List.length r.Query_engine.bindings <= 1); Lwt.return_unit
      | Error e -> Alcotest.fail e)

(* --- exact typed-literal matching --- *)

let test_exact_typed_literal_match () =
  with_pack "typed_literal" (fun store ->
      let query = parse_query_exn "birth_year(Person, @1951)" in
      let* result = Db.execute_query store query in
      match result with
      | Ok r ->
          Alcotest.(check int) "one match" 1 (List.length r.Query_engine.bindings);
          (match r.Query_engine.bindings with
          | [ b ] -> Alcotest.(check bool) "correct person" true (Value.equal (binding_value b "Person") (Value.Atom "tina_keane"))
          | _ -> Alcotest.fail "expected one binding");
          Lwt.return_unit
      | Error e -> Alcotest.fail e)

(* --- numeric / date / instant comparisons --- *)

let test_numeric_comparison () =
  with_pack "numeric_cmp" (fun store ->
      let query = parse_query_exn "confidence(Assertion, Score), Score >= 0.8" in
      let* result = Db.execute_query store query in
      match result with
      | Ok r ->
          Alcotest.(check int) "one match" 1 (List.length r.Query_engine.bindings);
          Lwt.return_unit
      | Error e -> Alcotest.fail e)

let test_year_range_comparison () =
  with_pack "year_cmp" (fun store ->
      let query = parse_query_exn "birth_year(Person, Year), Year >= 1945, Year < 1960" in
      let* result = Db.execute_query store query in
      match result with
      | Ok r ->
          Alcotest.(check int) "only tina_keane (1951)" 1 (List.length r.Query_engine.bindings);
          Lwt.return_unit
      | Error e -> Alcotest.fail e)

let test_date_comparison () =
  with_pack "date_cmp" (fun store ->
      let query = parse_query_exn "opened(Exhibition, Date), Date between @2019-01-01 and @2019-12-31" in
      let* result = Db.execute_query store query in
      match result with
      | Ok r -> Alcotest.(check int) "one exhibition in 2019" 1 (List.length r.Query_engine.bindings); Lwt.return_unit
      | Error e -> Alcotest.fail e)

let test_instant_comparison () =
  with_pack "instant_cmp" (fun store ->
      let query =
        parse_query_exn
          "captured_at(Capture, Date), Date >= @2022-01-01T00:00:00Z, Date < @2023-01-01T00:00:00Z"
      in
      let* result = Db.execute_query store query in
      match result with
      | Ok r -> Alcotest.(check int) "one capture in 2022" 1 (List.length r.Query_engine.bindings); Lwt.return_unit
      | Error e -> Alcotest.fail e)

let test_between () =
  with_pack "between" (fun store ->
      let query = parse_query_exn "birth_year(Person, Year), Year between 1940 and 1945" in
      let* result = Db.execute_query store query in
      match result with
      | Ok r -> Alcotest.(check int) "one match" 1 (List.length r.Query_engine.bindings); Lwt.return_unit
      | Error e -> Alcotest.fail e)

(* --- joins --- *)

let test_shared_variable_join () =
  with_pack "join" (fun store ->
      let query = parse_query_exn "created(Artist, Work), shown_in(Work, Exhibition)" in
      let* result = Db.execute_query store query in
      match result with
      | Ok r ->
          Alcotest.(check int) "one joined result" 1 (List.length r.Query_engine.bindings);
          (match r.Query_engine.bindings with
          | [ b ] -> Alcotest.(check bool) "artist bound" true (Value.equal (binding_value b "Artist") (Value.Atom "tina_keane"))
          | _ -> Alcotest.fail "expected one binding");
          Lwt.return_unit
      | Error e -> Alcotest.fail e)

(* --- type mismatch errors --- *)

let test_type_mismatch_error () =
  with_pack "type_mismatch" (fun store ->
      let query = parse_query_exn "opened(Exhibition, Date), Date < 1979" in
      let* result = Db.execute_query store query in
      match result with
      | Ok _ -> Alcotest.fail "expected a type mismatch error"
      | Error msg ->
          Alcotest.(check bool) "mentions date" true (contains_substring (String.lowercase_ascii msg) "date");
          Lwt.return_unit)

(* --- query planning --- *)

let test_range_index_planning () =
  let query = parse_query_exn "opened(Exhibition, Date), Date >= @2019-01-01, Date < @2020-01-01" in
  let explanation = Query_engine.explain query in
  Alcotest.(check bool) "uses range_index" true (contains_substring explanation "range_index")

let test_fallback_full_scan () =
  let query = parse_query_exn "artist(Person)" in
  let explanation = Query_engine.explain query in
  Alcotest.(check bool) "falls back to full scan" true (contains_substring explanation "full_scan")

let () =
  Alcotest.run "BeingDB DB"
    [
      ( "Predicates",
        [
          Alcotest.test_case "list_predicates" `Quick test_list_predicates;
          Alcotest.test_case "list_predicates_with_samples" `Quick test_list_predicates_with_samples;
          Alcotest.test_case "query_predicate" `Quick test_query_predicate;
          Alcotest.test_case "query_predicate respects limit" `Quick test_query_predicate_limit;
          Alcotest.test_case "predicate_exists true" `Quick test_predicate_exists_true;
          Alcotest.test_case "predicate_exists false" `Quick test_predicate_exists_false;
        ] );
      ( "Pattern queries",
        [
          Alcotest.test_case "simple pattern" `Quick test_execute_simple_pattern_query;
          Alcotest.test_case "streaming pagination" `Quick test_execute_query_streaming;
          Alcotest.test_case "exact typed literal" `Quick test_exact_typed_literal_match;
        ] );
      ( "Comparisons",
        [
          Alcotest.test_case "numeric >=" `Quick test_numeric_comparison;
          Alcotest.test_case "year range" `Quick test_year_range_comparison;
          Alcotest.test_case "date between" `Quick test_date_comparison;
          Alcotest.test_case "instant range" `Quick test_instant_comparison;
          Alcotest.test_case "between" `Quick test_between;
        ] );
      ("Joins", [ Alcotest.test_case "shared variable join" `Quick test_shared_variable_join ]);
      ("Errors", [ Alcotest.test_case "type mismatch" `Quick test_type_mismatch_error ]);
      ( "Planning",
        [
          Alcotest.test_case "range index selected" `Quick test_range_index_planning;
          Alcotest.test_case "fallback to full scan" `Quick test_fallback_full_scan;
        ] );
    ]

