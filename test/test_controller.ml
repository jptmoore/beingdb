(** Unit tests for Controller layer: JSON serialization and query
    execution, including the typed JSON result format. *)

open Beingdb

(** Helper: Create test Pack store *)
let create_test_pack name =
  let test_dir = Filename.concat (Filename.get_temp_dir_name ()) 
                   (Printf.sprintf "beingdb_controller_test_%s_%d" name (Unix.getpid ())) in
  
  (try Unix.rmdir test_dir with _ -> ());
  Unix.mkdir test_dir 0o755;
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* store = Pack_backend.init ~fresh:true test_dir in
    
    (* Add test data *)
    let by_predicate =
      [
        ("created", [ Fact.make "created" [ Value.Atom "tina_keane"; Value.Atom "she" ];
                      Fact.make "created" [ Value.Atom "lynn_hershman"; Value.Atom "lorna" ] ]);
        ("shown_in", [ Fact.make "shown_in" [ Value.Atom "she"; Value.Atom "rewind_1995" ] ]);
        ("artist", [ Fact.make "artist" [ Value.Atom "tina_keane" ]; Fact.make "artist" [ Value.Atom "lynn_hershman" ] ]);
        ( "label",
          [ Fact.make "label" [ Value.Atom "org_1"; Value.Lang_string { value = "National Archives"; language = "en" } ] ] );
        ("confidence", [ Fact.make "confidence" [ Value.Atom "assertion_1"; Value.Decimal (Decimal.make 92L 2) ] ]);
        ( "captured_at",
          [
            Fact.make "captured_at"
              [
                Value.Atom "capture_1";
                (match Calendar.parse_instant "2026-08-06T12:15:00Z" with Ok t -> Value.Instant t | Error e -> failwith e);
              ];
          ] );
        ("homepage", [ Fact.make "homepage" [ Value.Atom "org_1"; Value.Uri "https://example.org/" ] ]);
      ]
    in
    let* () =
      Lwt_list.iter_s
        (fun (pred, facts) -> Pack_backend.write_predicate_batch store pred facts (Printf.sprintf "compile %s" pred))
        by_predicate
    in
    Lwt.return (store, test_dir)
  )

let cleanup test_dir =
  let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
  let _ = Unix.system cmd in
  ()

(** Test: list_predicates without samples *)
let test_list_predicates () =
  let (store, test_dir) = create_test_pack "list_preds" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* result = Beingdb.Controller.list_predicates ~samples:None store in
    
    match result with
    | Ok json ->
        let predicates = Yojson.Safe.Util.member "predicates" json in
        let pred_list = Yojson.Safe.Util.to_list predicates in
        Alcotest.(check bool) "has predicates" true (List.length pred_list >= 3);
        
        (* Check no samples field *)
        List.iter (fun pred ->
          let members = Yojson.Safe.Util.keys pred in
          Alcotest.(check bool) "no samples" false (List.mem "samples" members)
        ) pred_list;
        
        cleanup test_dir;
        Lwt.return ()
    | Error _ ->
        cleanup test_dir;
        Alcotest.fail "Controller returned error"
  )

(** Test: list_predicates with samples *)
let test_list_predicates_with_samples () =
  let (store, test_dir) = create_test_pack "list_samples" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* result = Beingdb.Controller.list_predicates ~samples:(Some 5) store in
    
    match result with
    | Ok json ->
        let predicates = Yojson.Safe.Util.member "predicates" json in
        let pred_list = Yojson.Safe.Util.to_list predicates in
        
        (* At least one should have samples *)
        let has_samples = List.exists (fun pred ->
          let members = Yojson.Safe.Util.keys pred in
          List.mem "samples" members
        ) pred_list in
        
        Alcotest.(check bool) "has samples" true has_samples;
        
        cleanup test_dir;
        Lwt.return ()
    | Error _ ->
        cleanup test_dir;
        Alcotest.fail "Controller returned error"
  )

(** Test: query_predicate returns JSON results *)
let test_query_predicate () =
  let (store, test_dir) = create_test_pack "query_pred" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* result = Beingdb.Controller.query_predicate ~max_results:100 store "created" in
    
    match result with
    | Ok json ->
        let results = Yojson.Safe.Util.member "facts" json in
        let results_list = Yojson.Safe.Util.to_list results in
        Alcotest.(check bool) "has results" true (List.length results_list > 0);
        Alcotest.(check int) "has 2 results" 2 (List.length results_list);
        
        cleanup test_dir;
        Lwt.return ()
    | Error err ->
        cleanup test_dir;
        Alcotest.fail ("Query failed: " ^ err)
  )

(** Test: query_predicate respects max_results *)
let test_query_predicate_max_results () =
  let (store, test_dir) = create_test_pack "max_results" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* result = Beingdb.Controller.query_predicate ~max_results:1 store "artist" in
    
    match result with
    | Ok json ->
        let results = Yojson.Safe.Util.member "facts" json in
        let results_list = Yojson.Safe.Util.to_list results in
        Alcotest.(check bool) "respects max_results" true (List.length results_list <= 1);
        
        cleanup test_dir;
        Lwt.return ()
    | Error _ ->
        cleanup test_dir;
        Alcotest.fail "Query failed"
  )

(** Test: query_predicate returns empty for non-existent predicate *)
let test_query_nonexistent_predicate () =
  let (store, test_dir) = create_test_pack "nonexistent" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* result = Beingdb.Controller.query_predicate ~max_results:100 store "nonexistent" in
    
    match result with
    | Ok json ->
        let facts = Yojson.Safe.Util.member "facts" json in
        let facts_list = Yojson.Safe.Util.to_list facts in
        Alcotest.(check int) "empty results" 0 (List.length facts_list);
        cleanup test_dir;
        Lwt.return ()
    | Error err ->
        cleanup test_dir;
        Alcotest.fail ("Query failed: " ^ err)
  )

(** Test: execute_query simple query *)
let test_execute_query_simple () =
  let (store, test_dir) = create_test_pack "simple_query" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let query = "created(Artist, Work)" in
    let* result = Beingdb.Controller.execute_query ~max_results:100 store query ~offset:None ~limit:None in
    
    match result with
    | Ok json ->
        let results = Yojson.Safe.Util.member "results" json in
        let results_list = Yojson.Safe.Util.to_list results in
        Alcotest.(check bool) "has results" true (List.length results_list > 0);
        
        (* Check variables *)
        let vars = Yojson.Safe.Util.member "variables" json in
        let vars_list = Yojson.Safe.Util.to_list vars in
        Alcotest.(check int) "has 2 variables" 2 (List.length vars_list);
        
        cleanup test_dir;
        Lwt.return ()
    | Error err ->
        cleanup test_dir;
        Alcotest.fail ("Query failed: " ^ err)
  )

(** Test: execute_query with join *)
let test_execute_query_join () =
  let (store, test_dir) = create_test_pack "join_query" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let query = "created(Artist, Work), shown_in(Work, Event)" in
    let* result = Beingdb.Controller.execute_query ~max_results:100 store query ~offset:None ~limit:None in
    
    match result with
    | Ok json ->
        let results = Yojson.Safe.Util.member "results" json in
        let results_list = Yojson.Safe.Util.to_list results in
        Alcotest.(check bool) "has results" true (List.length results_list > 0);
        
        cleanup test_dir;
        Lwt.return ()
    | Error err ->
        cleanup test_dir;
        Alcotest.fail ("Query failed: " ^ err)
  )

(** Test: execute_query with pagination *)
let test_execute_query_pagination () =
  let (store, test_dir) = create_test_pack "pagination" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let query = "created(Artist, Work)" in
    let* result = Beingdb.Controller.execute_query ~max_results:100 store query ~offset:(Some 1) ~limit:(Some 1) in
    
    match result with
    | Ok json ->
        let open Yojson.Safe.Util in
        
        (* Check results *)
        let results = member "results" json in
        let results_list = to_list results in
        Alcotest.(check bool) "respects limit" true (List.length results_list <= 1);
        
        (* Check pagination metadata *)
        let count = member "count" json |> to_int in
        let total = member "total" json |> to_int in
        let offset = member "offset" json |> to_int in
        let limit = member "limit" json |> to_int in
        
        Alcotest.(check int) "count matches results" (List.length results_list) count;
        Alcotest.(check bool) "total >= count" true (total >= count);
        Alcotest.(check int) "offset is 1" 1 offset;
        Alcotest.(check int) "limit is 1" 1 limit;
        
        cleanup test_dir;
        Lwt.return ()
    | Error err ->
        cleanup test_dir;
        Alcotest.fail ("Query failed: " ^ err)
  )

(** Test: execute_query validation - empty query *)
let test_execute_query_empty () =
  let (store, test_dir) = create_test_pack "empty_query" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let query = "" in
    let* result = Beingdb.Controller.execute_query ~max_results:100 store query ~offset:None ~limit:None in
    
    match result with
    | Ok _ ->
        cleanup test_dir;
        Alcotest.fail "Empty query should fail"
    | Error err ->
        Alcotest.(check bool) "error mentions empty" true (String.length err > 0);
        cleanup test_dir;
        Lwt.return ()
  )

(** Test: execute_query validation - invalid syntax *)
let test_execute_query_invalid () =
  let (store, test_dir) = create_test_pack "invalid_query" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let query = "this is not a valid query!!!" in
    let* result = Beingdb.Controller.execute_query ~max_results:100 store query ~offset:None ~limit:None in
    
    match result with
    | Ok _ ->
        cleanup test_dir;
        Alcotest.fail "Invalid query should fail"
    | Error err ->
        Alcotest.(check bool) "returns error" true (String.length err > 0);
        cleanup test_dir;
        Lwt.return ()
  )

(** Test: execute_query respects max_results *)
let test_execute_query_max_results () =
  let (store, test_dir) = create_test_pack "max_query_results" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let query = "created(Artist, Work)" in
    let* result = Beingdb.Controller.execute_query ~max_results:1 store query ~offset:None ~limit:None in
    
    match result with
    | Ok json ->
        let results = Yojson.Safe.Util.member "results" json in
        let results_list = Yojson.Safe.Util.to_list results in
        Alcotest.(check bool) "respects max_results" true (List.length results_list <= 1);
        
        cleanup test_dir;
        Lwt.return ()
    | Error err ->
        cleanup test_dir;
        Alcotest.fail ("Query failed: " ^ err)
  )

(** Test: execute_query JSON structure without pagination *)
let test_execute_query_json_structure () =
  let (store, test_dir) = create_test_pack "json_structure" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let query = "created(Artist, Work)" in
    let* result = Beingdb.Controller.execute_query ~max_results:100 store query ~offset:None ~limit:None in
    
    match result with
    | Ok json ->
        let open Yojson.Safe.Util in
        
        (* Verify required fields exist *)
        let variables = member "variables" json |> to_list in
        let results = member "results" json |> to_list in
        let count = member "count" json |> to_int in
        let total = member "total" json |> to_int in
        
        (* Verify basic structure *)
        Alcotest.(check bool) "has variables" true (List.length variables > 0);
        Alcotest.(check bool) "has results" true (List.length results > 0);
        Alcotest.(check int) "count matches results" (List.length results) count;
        Alcotest.(check bool) "total >= count" true (total >= count);
        
        (* When no explicit pagination, limit is set to max_results (safety feature) *)
        let limit = member "limit" json |> to_int in
        Alcotest.(check int) "limit equals max_results" 100 limit;
        
        cleanup test_dir;
        Lwt.return ()
    | Error err ->
        cleanup test_dir;
        Alcotest.fail ("Query failed: " ^ err)
  )

(* --- typed JSON serialization --- *)

let json_value_field predicate store field =
  let open Lwt.Syntax in
  let* result = Controller.execute_query ~max_results:100 store predicate ~offset:None ~limit:None in
  match result with
  | Error e -> Alcotest.fail e
  | Ok json ->
      let open Yojson.Safe.Util in
      let first_result = json |> member "results" |> to_list |> List.hd in
      Lwt.return (first_result |> member field)

let test_typed_json_decimal () =
  let (store, test_dir) = create_test_pack "typed_json_decimal" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* value = json_value_field "confidence(Assertion, Score)" store "Score" in
     let open Yojson.Safe.Util in
     Alcotest.(check string) "type is decimal" "decimal" (value |> member "type" |> to_string);
     Alcotest.(check string) "exact decimal string" "0.92" (value |> member "value" |> to_string);
     cleanup test_dir;
     Lwt.return ())

let test_typed_json_instant () =
  let (store, test_dir) = create_test_pack "typed_json_instant" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* value = json_value_field "captured_at(Capture, When)" store "When" in
     let open Yojson.Safe.Util in
     Alcotest.(check string) "type is instant" "instant" (value |> member "type" |> to_string);
     Alcotest.(check string) "normalized UTC instant" "2026-08-06T12:15:00Z" (value |> member "value" |> to_string);
     cleanup test_dir;
     Lwt.return ())

let test_typed_json_lang_string () =
  let (store, test_dir) = create_test_pack "typed_json_lang" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* value = json_value_field "label(Org, Label)" store "Label" in
     let open Yojson.Safe.Util in
     Alcotest.(check string) "type is lang_string" "lang_string" (value |> member "type" |> to_string);
     Alcotest.(check string) "value includes language tag" "National Archives@en" (value |> member "value" |> to_string);
     cleanup test_dir;
     Lwt.return ())

let test_typed_json_uri () =
  let (store, test_dir) = create_test_pack "typed_json_uri" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* value = json_value_field "homepage(Org, Url)" store "Url" in
     let open Yojson.Safe.Util in
     Alcotest.(check string) "type is uri" "uri" (value |> member "type" |> to_string);
     Alcotest.(check string) "uri value" "https://example.org/" (value |> member "value" |> to_string);
     cleanup test_dir;
     Lwt.return ())

(* --- run_query: unified language/action dispatch --- *)

let test_run_query_core_execute () =
  let store, test_dir = create_test_pack "run_core_exec" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* outcome = Controller.run_query ~max_results:100 store "created(Artist, Work)" ~offset:None ~limit:None in
     (match outcome with
     | Controller.Success json ->
         let results = Yojson.Safe.Util.(json |> member "results" |> to_list) in
         Alcotest.(check bool) "has results" true (List.length results > 0)
     | Controller.Invalid _ -> Alcotest.fail "expected Success, got Invalid"
     | Controller.Failure msg -> Alcotest.fail ("expected Success, got Failure: " ^ msg));
     cleanup test_dir;
     Lwt.return ())

let test_run_query_core_validate () =
  let store, test_dir = create_test_pack "run_core_validate" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* outcome = Controller.run_query ~max_results:100 ~action:"validate" store "created(Artist, Work)" ~offset:None ~limit:None in
     (match outcome with
     | Controller.Success json -> Alcotest.(check bool) "valid true" true (Yojson.Safe.Util.(json |> member "valid" |> to_bool))
     | _ -> Alcotest.fail "expected Success");
     cleanup test_dir;
     Lwt.return ())

let test_run_query_core_explain () =
  let store, test_dir = create_test_pack "run_core_explain" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* outcome = Controller.run_query ~max_results:100 ~action:"explain" store "created(Artist, Work)" ~offset:None ~limit:None in
     (match outcome with
     | Controller.Success json -> Alcotest.(check bool) "has plan" true (String.length Yojson.Safe.Util.(json |> member "plan" |> to_string) > 0)
     | _ -> Alcotest.fail "expected Success");
     cleanup test_dir;
     Lwt.return ())

let test_run_query_dsl_execute () =
  let store, test_dir = create_test_pack "run_dsl_exec" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let query = "find Artist\nwhere\n  artist(Artist)\n" in
     let* outcome = Controller.run_query ~max_results:100 ~language:"dsl" store query ~offset:None ~limit:None in
     (match outcome with
     | Controller.Success json ->
         let results = Yojson.Safe.Util.(json |> member "results" |> to_list) in
         Alcotest.(check int) "2 artists" 2 (List.length results)
     | Controller.Invalid j -> Alcotest.fail ("expected Success, got Invalid: " ^ Yojson.Safe.to_string j)
     | Controller.Failure msg -> Alcotest.fail ("expected Success, got Failure: " ^ msg));
     cleanup test_dir;
     Lwt.return ())

(** Regression: a query whose ENTIRE where-clause is a group (no
    top-level pattern -- every pattern nested inside `either`/`or`) must
    still pass the safety validator's "has at least one pattern" check,
    which must recurse into nested groups rather than only look at
    top-level clauses. *)
let test_run_query_dsl_execute_top_level_alternatives () =
  let store, test_dir = create_test_pack "run_dsl_top_alt" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let query = "find Artist\nwhere\n  either\n    artist(Artist)\n  or\n    artist(Artist)\n" in
     let* outcome = Controller.run_query ~max_results:100 ~language:"dsl" store query ~offset:None ~limit:None in
     (match outcome with
     | Controller.Success json ->
         let results = Yojson.Safe.Util.(json |> member "results" |> to_list) in
         Alcotest.(check bool) "has results" true (List.length results > 0)
     | Controller.Invalid j -> Alcotest.fail ("expected Success, got Invalid: " ^ Yojson.Safe.to_string j)
     | Controller.Failure msg -> Alcotest.fail ("expected Success, got Failure: " ^ msg));
     cleanup test_dir;
     Lwt.return ())

let test_run_query_dsl_validate_unknown_predicate () =
  let store, test_dir = create_test_pack "run_dsl_validate" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let query = "find X\nwhere\n  artst(X)\n" in
     let* outcome = Controller.run_query ~max_results:100 ~language:"dsl" ~action:"validate" store query ~offset:None ~limit:None in
     (match outcome with
     | Controller.Invalid json ->
         Alcotest.(check bool) "valid false" false (Yojson.Safe.Util.(json |> member "valid" |> to_bool));
         let errors = Yojson.Safe.Util.(json |> member "errors" |> to_list) in
         Alcotest.(check bool) "has errors" true (List.length errors > 0)
     | Controller.Success _ -> Alcotest.fail "expected Invalid"
     | Controller.Failure msg -> Alcotest.fail ("expected Invalid, got Failure: " ^ msg));
     cleanup test_dir;
     Lwt.return ())

let test_run_query_dsl_explain () =
  let store, test_dir = create_test_pack "run_dsl_explain" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let query = "find Artist\nwhere\n  artist(Artist)\n" in
     let* outcome = Controller.run_query ~max_results:100 ~language:"dsl" ~action:"explain" store query ~offset:None ~limit:None in
     (match outcome with
     | Controller.Success json -> Alcotest.(check bool) "has plan" true (String.length Yojson.Safe.Util.(json |> member "plan" |> to_string) > 0)
     | _ -> Alcotest.fail "expected Success");
     cleanup test_dir;
     Lwt.return ())

let test_run_query_unknown_language () =
  let store, test_dir = create_test_pack "run_unknown_lang" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* outcome = Controller.run_query ~max_results:100 ~language:"sparql" store "created(A, W)" ~offset:None ~limit:None in
     (match outcome with Controller.Failure _ -> () | _ -> Alcotest.fail "expected Failure");
     cleanup test_dir;
     Lwt.return ())

let () =
  Alcotest.run "BeingDB Controller" [
    "List Predicates", [
      Alcotest.test_case "list_predicates without samples" `Quick test_list_predicates;
      Alcotest.test_case "list_predicates with samples" `Quick test_list_predicates_with_samples;
    ];
    "Query Predicate", [
      Alcotest.test_case "query_predicate" `Quick test_query_predicate;
      Alcotest.test_case "query_predicate max_results" `Quick test_query_predicate_max_results;
      Alcotest.test_case "query_predicate nonexistent" `Quick test_query_nonexistent_predicate;
    ];
    "Execute Query", [
      Alcotest.test_case "execute_query simple" `Quick test_execute_query_simple;
      Alcotest.test_case "execute_query join" `Quick test_execute_query_join;
      Alcotest.test_case "execute_query pagination" `Quick test_execute_query_pagination;
      Alcotest.test_case "execute_query max_results" `Quick test_execute_query_max_results;
      Alcotest.test_case "execute_query JSON structure" `Quick test_execute_query_json_structure;
    ];
    "Validation", [
      Alcotest.test_case "execute_query empty" `Quick test_execute_query_empty;
      Alcotest.test_case "execute_query invalid" `Quick test_execute_query_invalid;
    ];
    "Typed JSON", [
      Alcotest.test_case "decimal preserved exactly as string" `Quick test_typed_json_decimal;
      Alcotest.test_case "instant normalized output" `Quick test_typed_json_instant;
      Alcotest.test_case "language-tagged string output" `Quick test_typed_json_lang_string;
      Alcotest.test_case "uri output" `Quick test_typed_json_uri;
    ];
    "Run Query dispatch", [
      Alcotest.test_case "core execute" `Quick test_run_query_core_execute;
      Alcotest.test_case "core validate" `Quick test_run_query_core_validate;
      Alcotest.test_case "core explain" `Quick test_run_query_core_explain;
      Alcotest.test_case "dsl execute" `Quick test_run_query_dsl_execute;
      Alcotest.test_case "dsl execute top-level alternatives" `Quick test_run_query_dsl_execute_top_level_alternatives;
      Alcotest.test_case "dsl validate unknown predicate" `Quick test_run_query_dsl_validate_unknown_predicate;
      Alcotest.test_case "dsl explain" `Quick test_run_query_dsl_explain;
      Alcotest.test_case "unknown language" `Quick test_run_query_unknown_language;
    ];
  ]
