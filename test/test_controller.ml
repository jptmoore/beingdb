(** Unit tests for Controller layer *)

(** Helper: Create test Pack store *)
let create_test_pack name =
  let test_dir = Filename.concat (Filename.get_temp_dir_name ()) 
                   (Printf.sprintf "beingdb_controller_test_%s_%d" name (Unix.getpid ())) in
  
  (try Unix.rmdir test_dir with _ -> ());
  Unix.mkdir test_dir 0o755;
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* store = Beingdb.Pack_backend.init ~fresh:true test_dir in
    
    (* Add test data *)
    let facts = [
      ("created", [Beingdb.Types.Atom "tina_keane"; Beingdb.Types.Atom "she"]);
      ("created", [Beingdb.Types.Atom "lynn_hershman"; Beingdb.Types.Atom "lorna"]);
      ("shown_in", [Beingdb.Types.Atom "she"; Beingdb.Types.Atom "rewind_1995"]);
      ("artist", [Beingdb.Types.Atom "tina_keane"]);
      ("artist", [Beingdb.Types.Atom "lynn_hershman"]);
    ] in
    
    let* () = Lwt_list.iter_s (fun (pred, args) ->
      Beingdb.Pack_backend.write_fact store pred args
    ) facts in
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
  ]
