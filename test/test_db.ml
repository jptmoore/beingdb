(** Unit tests for DB layer *)

(** Helper: Create test Pack store *)
let create_test_pack name =
  let test_dir = Filename.concat (Filename.get_temp_dir_name ()) 
                   (Printf.sprintf "beingdb_db_test_%s_%d" name (Unix.getpid ())) in
  
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

(** Test: list_predicates returns all predicates with arities *)
let test_list_predicates () =
  let (store, test_dir) = create_test_pack "list_predicates" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* predicates = Beingdb.Db.list_predicates store in
    
    (* Should have created, shown_in, artist *)
    Alcotest.(check bool) "has predicates" true (List.length predicates >= 3);
    
    (* Check structure *)
    List.iter (fun (name, arity) ->
      Alcotest.(check bool) "name is string" true (String.length name > 0);
      Alcotest.(check bool) "arity is positive" true (arity > 0)
    ) predicates;
    
    (* Check specific predicates *)
    let has_created = List.exists (fun (name, arity) -> name = "created" && arity = 2) predicates in
    let has_artist = List.exists (fun (name, arity) -> name = "artist" && arity = 1) predicates in
    
    Alcotest.(check bool) "has created/2" true has_created;
    Alcotest.(check bool) "has artist/1" true has_artist;
    
    cleanup test_dir;
    Lwt.return ()
  )

(** Test: list_predicates_with_samples returns samples *)
let test_list_predicates_with_samples () =
  let (store, test_dir) = create_test_pack "list_samples" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* predicates = Beingdb.Db.list_predicates_with_samples ~samples:5 store in
    
    Alcotest.(check bool) "has predicates" true (List.length predicates >= 3);
    
    (* Check at least one has samples *)
    let has_samples = List.exists (fun (_, _, samples_opt) ->
      match samples_opt with
      | Some samples -> List.length samples > 0
      | None -> false
    ) predicates in
    
    Alcotest.(check bool) "at least one predicate has samples" true has_samples;
    
    cleanup test_dir;
    Lwt.return ()
  )

(** Test: query_predicate returns facts *)
let test_query_predicate () =
  let (store, test_dir) = create_test_pack "query_pred" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* results = Beingdb.Db.query_predicate ~limit:100 store "created" in
    
    Alcotest.(check bool) "has results" true (List.length results > 0);
    Alcotest.(check int) "has 2 created facts" 2 (List.length results);
    
    cleanup test_dir;
    Lwt.return ()
  )

(** Test: query_predicate respects limit *)
let test_query_predicate_limit () =
  let (store, test_dir) = create_test_pack "query_limit" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* results = Beingdb.Db.query_predicate ~limit:1 store "artist" in
    
    Alcotest.(check bool) "respects limit" true (List.length results <= 1);
    
    cleanup test_dir;
    Lwt.return ()
  )

(** Test: predicate_exists returns true for existing predicate *)
let test_predicate_exists_true () =
  let (store, test_dir) = create_test_pack "pred_exists" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* exists = Beingdb.Db.predicate_exists store "created" in
    
    Alcotest.(check bool) "created exists" true exists;
    
    cleanup test_dir;
    Lwt.return ()
  )

(** Test: predicate_exists returns false for non-existing predicate *)
let test_predicate_exists_false () =
  let (store, test_dir) = create_test_pack "pred_not_exists" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* exists = Beingdb.Db.predicate_exists store "nonexistent" in
    
    Alcotest.(check bool) "nonexistent doesn't exist" false exists;
    
    cleanup test_dir;
    Lwt.return ()
  )

(** Test: execute_query returns results for simple query *)
let test_execute_query () =
  let (store, test_dir) = create_test_pack "execute_query" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    
    (* Parse query *)
    let query_str = "created(Artist, Work)" in
    let query = match Beingdb.Query_parser.parse_query query_str with
      | Some q -> q
      | None -> Alcotest.fail "Query parsing failed"
    in
    
    let* result = Beingdb.Db.execute_query store query in
    
    Alcotest.(check bool) "has bindings" true (List.length result.Beingdb.Query_engine.bindings > 0);
    Alcotest.(check bool) "has variables" true (List.length result.variables > 0);
    
    cleanup test_dir;
    Lwt.return ()
  )

(** Test: execute_query_streaming returns paginated results *)
let test_execute_query_streaming () =
  let (store, test_dir) = create_test_pack "streaming" in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    
    let query_str = "created(Artist, Work), shown_in(Work, Event)" in
    let query = match Beingdb.Query_parser.parse_query query_str with
      | Some q -> q
      | None -> Alcotest.fail "Query parsing failed"
    in
    
    let* result = Beingdb.Db.execute_query_streaming store query ~offset:0 ~limit:1 in
    
    Alcotest.(check bool) "respects limit" true (List.length result.Beingdb.Query_engine.bindings <= 1);
    
    cleanup test_dir;
    Lwt.return ()
  )

let () =
  Alcotest.run "BeingDB DB" [
    "Predicates", [
      Alcotest.test_case "list_predicates" `Quick test_list_predicates;
      Alcotest.test_case "list_predicates_with_samples" `Quick test_list_predicates_with_samples;
    ];
    "Query Predicate", [
      Alcotest.test_case "query_predicate" `Quick test_query_predicate;
      Alcotest.test_case "query_predicate respects limit" `Quick test_query_predicate_limit;
    ];
    "Predicate Exists", [
      Alcotest.test_case "predicate_exists true" `Quick test_predicate_exists_true;
      Alcotest.test_case "predicate_exists false" `Quick test_predicate_exists_false;
    ];
    "Execute Query", [
      Alcotest.test_case "execute_query" `Quick test_execute_query;
      Alcotest.test_case "execute_query_streaming" `Quick test_execute_query_streaming;
    ];
  ]
