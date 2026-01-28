(** Unit tests for BeingDB *)

open Lwt.Infix

(* Helper: Create testable for arg_value *)
let arg_value_testable =
  Alcotest.testable Beingdb.Types.pp_arg_value (=)

let arg_value_list_testable =
  Alcotest.list arg_value_testable

let fact_testable =
  Alcotest.pair Alcotest.string arg_value_list_testable

(* Helper: Convert string list to Atom list for convenience *)
let atoms strs = List.map (fun s -> Beingdb.Types.Atom s) strs

let test_parse_fact () =
  let open Beingdb.Parse_predicate in
  let open Beingdb.Types in
  
  (* Test simple fact *)
  let fact1 = "created(tina_keane, she)." in
  let result1 = parse_fact fact1 in
  Alcotest.(check (option fact_testable))
    "parse simple fact" 
    (Some ("created", [Atom "tina_keane"; Atom "she"]))
    result1;
  
  (* Test fact without trailing dot *)
  let fact2 = "shown_in(she, rewind_exhibition_1995)" in
  let result2 = parse_fact fact2 in
  Alcotest.(check (option fact_testable))
    "parse fact without dot"
    (Some ("shown_in", [Atom "she"; Atom "rewind_exhibition_1995"]))
    result2;
  
  (* Test fact with spaces *)
  let fact3 = "created( tina_keane , she )." in
  let result3 = parse_fact fact3 in
  Alcotest.(check (option fact_testable))
    "parse fact with spaces"
    (Some ("created", [Atom "tina_keane"; Atom "she"]))
    result3;
  
  (* Test three-argument fact *)
  let fact4 = "relationship(subject, predicate, object)." in
  let result4 = parse_fact fact4 in
  Alcotest.(check (option fact_testable))
    "parse three-argument fact"
    (Some ("relationship", [Atom "subject"; Atom "predicate"; Atom "object"]))
    result4;
  
  (* Test single-argument fact *)
  let fact5 = "active(user123)." in
  let result5 = parse_fact fact5 in
  Alcotest.(check (option fact_testable))
    "parse single-argument fact"
    (Some ("active", [Atom "user123"]))
    result5;
  
  (* Test fact with quoted strings *)
  let fact6 = "keyword(doc_456, \"neural networks\")." in
  let result6 = parse_fact fact6 in
  Alcotest.(check (option fact_testable))
    "parse fact with quoted string"
    (Some ("keyword", [Atom "doc_456"; String "neural networks"]))
    result6;
  
  (* Test invalid facts *)
  let fact7 = "not_a_fact" in
  let result7 = parse_fact fact7 in
  Alcotest.(check (option fact_testable))
    "parse invalid fact (no parens)"
    None
    result7;
  
  (* Parser is lenient with unclosed parens - it just treats content as args *)
  let fact8 = "invalid(" in
  let result8 = parse_fact fact8 in
  Alcotest.(check (option fact_testable))
    "parse fact with unclosed parens (lenient parser)"
    (Some ("invalid", []))
    result8;
  
  let fact9 = "" in
  let result9 = parse_fact fact9 in
  Alcotest.(check (option fact_testable))
    "parse empty string"
    None
    result9

let test_git_backend () =
  Lwt_main.run begin
    let test_dir = Filename.temp_file "beingdb_test_git_" "" in
    Unix.unlink test_dir;
    Unix.mkdir test_dir 0o755;
    
    Beingdb.Git_backend.init test_dir
    >>= fun store ->
    
    (* Write some facts to 'created' predicate *)
    let created_facts = [
      "created(artist_a, work_1).";
      "created(artist_b, work_2).";
      "created(artist_a, work_3).";
    ] in
    let created_content = String.concat "\n" created_facts in
    Beingdb.Git_backend.write_predicate store "created" created_content
    >>= fun () ->
    
    (* Write facts to another predicate *)
    let shown_facts = [
      "shown_in(work_1, exhibition_a).";
      "shown_in(work_2, exhibition_b).";
    ] in
    let shown_content = String.concat "\n" shown_facts in
    Beingdb.Git_backend.write_predicate store "shown_in" shown_content
    >>= fun () ->
    
    (* Read 'created' facts back *)
    Beingdb.Git_backend.read_predicate store "created"
    >>= fun read_content ->
    
    let read_facts = match read_content with
      | Some content -> String.split_on_char '\n' content |> List.filter (fun s -> String.trim s <> "")
      | None -> []
    in
    
    Alcotest.(check (list string))
      "git backend read/write 'created'"
      created_facts
      read_facts;
    
    (* Read 'shown_in' facts back *)
    Beingdb.Git_backend.read_predicate store "shown_in"
    >>= fun shown_read ->
    
    let shown_read_facts = match shown_read with
      | Some content -> String.split_on_char '\n' content |> List.filter (fun s -> String.trim s <> "")
      | None -> []
    in
    
    Alcotest.(check (list string))
      "git backend read/write 'shown_in'"
      shown_facts
      shown_read_facts;
    
    (* List predicates *)
    Beingdb.Git_backend.list_predicates store
    >>= fun predicates ->
    
    let sorted_predicates = List.sort String.compare predicates in
    Alcotest.(check (list string))
      "git backend list predicates"
      ["created"; "shown_in"]
      sorted_predicates;
    
    (* Test reading non-existent predicate *)
    Beingdb.Git_backend.read_predicate store "nonexistent"
    >>= fun missing ->
    
    Alcotest.(check (option string))
      "git backend read missing predicate"
      None
      missing;
    
    (* Test overwriting a predicate *)
    let updated_facts = ["created(artist_c, work_4)."] in
    let updated_content = String.concat "\n" updated_facts in
    Beingdb.Git_backend.write_predicate store "created" updated_content
    >>= fun () ->
    
    Beingdb.Git_backend.read_predicate store "created"
    >>= fun updated_read ->
    
    let updated_read_facts = match updated_read with
      | Some content -> String.split_on_char '\n' content |> List.filter (fun s -> String.trim s <> "")
      | None -> []
    in
    
    Alcotest.(check (list string))
      "git backend overwrite predicate"
      updated_facts
      updated_read_facts;
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    
    Lwt.return ()
  end

let test_pack_backend () =
  Lwt_main.run begin
    let test_dir = Filename.temp_file "beingdb_test_pack_" "" in
    Unix.unlink test_dir;
    Unix.mkdir test_dir 0o755;
    
    Beingdb.Pack_backend.init ~fresh:true test_dir
    >>= fun store ->
    
    (* Write facts to 'created' predicate *)
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_a"; "work_1"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_b"; "work_2"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_a"; "work_3"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_c"; "work_4"])
    >>= fun () ->
    
    (* Write facts to 'shown_in' predicate *)
    Beingdb.Pack_backend.write_fact store "shown_in" (atoms ["work_1"; "exhibition_a"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "shown_in" (atoms ["work_2"; "exhibition_b"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "shown_in" (atoms ["work_3"; "exhibition_a"])
    >>= fun () ->
    
    (* Query all 'created' facts *)
    Beingdb.Pack_backend.query_all store "created"
    >>= fun all_created ->
    
    Alcotest.(check int)
      "pack backend stores 4 'created' facts"
      4
      (List.length all_created);
    
    (* Query all 'shown_in' facts *)
    Beingdb.Pack_backend.query_all store "shown_in"
    >>= fun all_shown ->
    
    Alcotest.(check int)
      "pack backend stores 3 'shown_in' facts"
      3
      (List.length all_shown);
    
    (* Query with pattern - all works by artist_a *)
    Beingdb.Pack_backend.query_predicate store "created" (atoms ["artist_a"; "_"])
    >>= fun artist_a_works ->
    
    Alcotest.(check int)
      "pack backend pattern match finds 2 works by artist_a"
      2
      (List.length artist_a_works);
    
    (* Query with pattern - find specific work *)
    Beingdb.Pack_backend.query_predicate store "created" (atoms ["_"; "work_2"])
    >>= fun work_2_facts ->
    
    Alcotest.(check int)
      "pack backend pattern match finds work_2"
      1
      (List.length work_2_facts);
    
    Alcotest.(check (list arg_value_list_testable))
      "pack backend work_2 created by artist_b"
      [atoms ["artist_b"; "work_2"]]
      work_2_facts;
    
    (* Query with pattern - works shown at exhibition_a *)
    Beingdb.Pack_backend.query_predicate store "shown_in" (atoms ["_"; "exhibition_a"])
    >>= fun exhibition_a_works ->
    
    Alcotest.(check int)
      "pack backend finds 2 works at exhibition_a"
      2
      (List.length exhibition_a_works);
    
    (* Query with wildcards in both positions *)
    Beingdb.Pack_backend.query_predicate store "created" (atoms ["_"; "_"])
    >>= fun all_wildcards ->
    
    Alcotest.(check int)
      "pack backend wildcard query returns all facts"
      4
      (List.length all_wildcards);
    
    (* Query non-existent predicate *)
    Beingdb.Pack_backend.query_all store "nonexistent"
    >>= fun empty_result ->
    
    Alcotest.(check int)
      "pack backend returns empty for non-existent predicate"
      0
      (List.length empty_result);
    
    (* List predicates *)
    Beingdb.Pack_backend.list_predicates store
    >>= fun predicates ->
    
    let sorted_predicates = List.sort String.compare predicates in
    Alcotest.(check (list string))
      "pack backend list predicates"
      ["created"; "shown_in"]
      sorted_predicates;
    
    (* List predicates with arity *)
    Beingdb.Pack_backend.list_predicates_with_arity store
    >>= fun predicates_with_arity ->
    
    let sorted_with_arity = List.sort (fun (a, _) (b, _) -> String.compare a b) predicates_with_arity in
    Alcotest.(check (list (pair string int)))
      "pack backend list predicates with arity"
      [("created", 2); ("shown_in", 2)]
      sorted_with_arity;
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    
    Lwt.return ()
  end

let test_query_engine () =
  Lwt_main.run begin
    let test_dir = Filename.temp_file "beingdb_test_query_" "" in
    Unix.unlink test_dir;
    Unix.mkdir test_dir 0o755;
    
    Beingdb.Pack_backend.init ~fresh:true test_dir
    >>= fun store ->
    
    (* Setup test data - artist creates works, works shown in exhibitions *)
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_a"; "work_1"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_a"; "work_2"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_b"; "work_3"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "shown_in" (atoms ["work_1"; "exhibition_x"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "shown_in" (atoms ["work_2"; "exhibition_y"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "shown_in" (atoms ["work_3"; "exhibition_x"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "held_at" (atoms ["exhibition_x"; "venue_london"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "held_at" (atoms ["exhibition_y"; "venue_paris"])
    >>= fun () ->
    
    (* Test simple pattern query *)
    (match Beingdb.Query_parser.parse_query "created(artist_a, Work)" with
    | None -> Lwt.fail_with "Failed to parse simple query"
    | Some query ->
        Beingdb.Query_engine.execute store query
        >>= fun result ->
        
        Alcotest.(check int)
          "query engine simple pattern returns 2 results"
          2
          (List.length result.bindings);
        
        Lwt.return ())
    >>= fun () ->
    
    (* Test join query: artist -> work -> exhibition *)
    (match Beingdb.Query_parser.parse_query "created(Artist, Work), shown_in(Work, Exhibition)" with
    | None -> Lwt.fail_with "Failed to parse join query"
    | Some query ->
        Beingdb.Query_engine.execute store query
        >>= fun result ->
        
        Alcotest.(check int)
          "query engine join returns 3 results"
          3
          (List.length result.bindings);
        
        (* Variables are extracted in order of appearance, deduplicated *)
        let sorted_expected = List.sort String.compare ["Artist"; "Work"; "Exhibition"] in
        let sorted_actual = List.sort String.compare result.variables in
        Alcotest.(check (list string))
          "query engine join has correct variables (order may vary)"
          sorted_expected
          sorted_actual;
        
        Lwt.return ())
    >>= fun () ->
    
    (* Test three-way join: artist -> work -> exhibition -> venue *)
    (match Beingdb.Query_parser.parse_query "created(Artist, Work), shown_in(Work, Exhibition), held_at(Exhibition, Venue)" with
    | None -> Lwt.fail_with "Failed to parse three-way join"
    | Some query ->
        Beingdb.Query_engine.execute store query
        >>= fun result ->
        
        Alcotest.(check int)
          "query engine three-way join returns 3 results"
          3
          (List.length result.bindings);
        
        let sorted_expected = List.sort String.compare ["Artist"; "Work"; "Exhibition"; "Venue"] in
        let sorted_actual = List.sort String.compare result.variables in
        Alcotest.(check (list string))
          "query engine three-way join has correct variables (order may vary)"
          sorted_expected
          sorted_actual;
        
        Lwt.return ())
    >>= fun () ->
    
    (* Test query with constants *)
    (match Beingdb.Query_parser.parse_query "created(artist_a, Work), shown_in(Work, exhibition_x)" with
    | None -> Lwt.fail_with "Failed to parse constant query"
    | Some query ->
        Beingdb.Query_engine.execute store query
        >>= fun result ->
        
        Alcotest.(check int)
          "query engine constant filter returns 1 result"
          1
          (List.length result.bindings);
        
        (* Should be work_1 *)
        (match result.bindings with
        | [binding] ->
            let work = List.assoc "Work" binding in
            Alcotest.(check string)
              "query engine constant filter returns work_1"
              "work_1"
              work;
            Lwt.return ()
        | _ -> Lwt.fail_with "Expected exactly one result"))
    >>= fun () ->
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    
    Lwt.return ()
  end

let test_pagination () =
  Lwt_main.run begin
    let open Lwt.Infix in
    let test_dir = Filename.temp_file "beingdb_test_pagination_" ".pack" in
    Unix.unlink test_dir;
    
    Beingdb.Pack_backend.init ~fresh:true test_dir
    >>= fun store ->
    
    (* Insert 5 test facts *)
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_1"; "work_1"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_2"; "work_2"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_3"; "work_3"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_4"; "work_4"])
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" (atoms ["artist_5"; "work_5"])
    >>= fun () ->
    
    (* Test offset without limit *)
    Beingdb.Pack_backend.query_predicate ~offset:2 store "created" (atoms ["_"; "_"])
    >>= fun offset_results ->
    
    Alcotest.(check int)
      "pagination: offset 2 returns 3 results"
      3
      (List.length offset_results);
    
    (* Test limit without offset *)
    Beingdb.Pack_backend.query_predicate ~limit:2 store "created" (atoms ["_"; "_"])
    >>= fun limit_results ->
    
    Alcotest.(check int)
      "pagination: limit 2 returns 2 results"
      2
      (List.length limit_results);
    
    (* Test offset and limit together *)
    Beingdb.Pack_backend.query_predicate ~offset:1 ~limit:2 store "created" (atoms ["_"; "_"])
    >>= fun paginated_results ->
    
    Alcotest.(check int)
      "pagination: offset 1 limit 2 returns 2 results"
      2
      (List.length paginated_results);
    
    (* Test pagination with result_to_json *)
    (match Beingdb.Query_parser.parse_query "created(Artist, Work)" with
    | None -> Lwt.fail_with "Failed to parse query"
    | Some query ->
        Beingdb.Query_engine.execute store query
        >>= fun result ->
        
        (* Check total count *)
        Alcotest.(check int)
          "pagination: total results is 5"
          5
          (List.length result.bindings);
        
        (* Format with pagination *)
        let json = Beingdb.Query_engine.result_to_json ~offset:1 ~limit:2 result in
        
        (* Extract fields from JSON *)
        let open Yojson.Safe.Util in
        let count = json |> member "count" |> to_int in
        let total = json |> member "total" |> to_int in
        let offset = json |> member "offset" |> to_int in
        let limit = json |> member "limit" |> to_int in
        
        Alcotest.(check int) "pagination: JSON count is 2" 2 count;
        Alcotest.(check int) "pagination: JSON total is 5" 5 total;
        Alcotest.(check int) "pagination: JSON offset is 1" 1 offset;
        Alcotest.(check int) "pagination: JSON limit is 2" 2 limit;
        
        Lwt.return ())
    >>= fun () ->
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    
    Lwt.return ()
  end

let test_arity_validation () =
  Lwt_main.run begin
    let test_dir_git = Filename.temp_file "beingdb_arity_git_" "" in
    Unix.unlink test_dir_git;
    Unix.mkdir test_dir_git 0o755;
    
    (* Initialize Git store *)
    Beingdb.Git_backend.init test_dir_git
    >>= fun git_store ->
    
    (* Write predicate with consistent arity (2 arguments) *)
    let consistent_facts = [
      "created(artist_a, work_1).";
      "created(artist_b, work_2).";
      "created(artist_c, work_3).";
    ] in
    Beingdb.Git_backend.write_predicate git_store "created" (String.concat "\n" consistent_facts)
    >>= fun () ->
    
    (* Write predicate with mixed arities (2 and 3 arguments) *)
    let mixed_facts = [
      "made(artist_a, work_1).";           (* 2 args *)
      "made(artist_b, work_2, 1995).";      (* 3 args *)
      "made(artist_c, work_3).";            (* 2 args *)
      "made(artist_d, work_4, 2000).";      (* 3 args *)
    ] in
    Beingdb.Git_backend.write_predicate git_store "made" (String.concat "\n" mixed_facts)
    >>= fun () ->
    
    (* Simulate compile for consistent predicate *)
    Beingdb.Git_backend.read_predicate git_store "created"
    >>= fun content_opt ->
    
    let consistent_content = match content_opt with
      | Some c -> c
      | None -> Alcotest.fail "Should have content for 'created'"
    in
    
    let facts = String.split_on_char '\n' consistent_content
      |> List.map String.trim
      |> List.filter (fun s -> s <> "")
    in
    
    let parse_results = List.map (fun fact ->
      match Beingdb.Parse_predicate.parse_fact fact with
      | None -> `Invalid fact
      | Some (pred, args) -> `Valid (pred, args, fact)
    ) facts in
    
    let parsed_facts = List.filter_map (function
      | `Invalid _ -> None
      | `Valid data -> Some data
    ) parse_results in
    
    let arities = List.map (fun (_, args, _) -> List.length args) parsed_facts in
    let unique_arities = List.sort_uniq compare arities in
    
    Alcotest.(check int)
      "consistent predicate has single arity"
      1
      (List.length unique_arities);
    
    Alcotest.(check int)
      "consistent predicate arity is 2"
      2
      (List.hd arities);
    
    (* Simulate compile for mixed-arity predicate *)
    Beingdb.Git_backend.read_predicate git_store "made"
    >>= fun mixed_content_opt ->
    
    let mixed_content = match mixed_content_opt with
      | Some c -> c
      | None -> Alcotest.fail "Should have content for 'made'"
    in
    
    let mixed_facts_parsed = String.split_on_char '\n' mixed_content
      |> List.map String.trim
      |> List.filter (fun s -> s <> "")
      |> List.map (fun fact ->
          match Beingdb.Parse_predicate.parse_fact fact with
          | None -> `Invalid fact
          | Some (pred, args) -> `Valid (pred, args, fact))
      |> List.filter_map (function
          | `Invalid _ -> None
          | `Valid data -> Some data)
    in
    
    let mixed_arities = List.map (fun (_, args, _) -> List.length args) mixed_facts_parsed in
    let unique_mixed_arities = List.sort_uniq compare mixed_arities in
    
    Alcotest.(check int)
      "mixed predicate has multiple arities"
      2
      (List.length unique_mixed_arities);
    
    Alcotest.(check (list int))
      "mixed predicate has arities 2 and 3"
      [2; 3]
      unique_mixed_arities;
    
    (* Verify that facts with mixed arity would be rejected during compile *)
    (* In real compile.ml, this would result in 0 facts written *)
    let should_write = List.length unique_mixed_arities = 1 in
    
    Alcotest.(check bool)
      "mixed arity predicate should be rejected"
      false
      should_write;
    
    (* Cleanup *)
    let cmd_git = Printf.sprintf "rm -rf %s" (Filename.quote test_dir_git) in
    let _ = Unix.system cmd_git in
    
    Lwt.return ()
  end

(** Test Query_safety validation *)
let test_query_safety_validation () =
  let open Beingdb.Query_safety in
  
  let query = {
    Beingdb.Query_parser.patterns = [
      { name = "created"; args = [Var "A"; Var "W"] };
    ];
    variables = ["A"; "W"];
  } in
  
  (* Valid: all parameters valid *)
  (match validate_query query (Some 0) (Some 10) with
  | Ok (offset, limit) ->
      Alcotest.(check (option int)) "valid offset" (Some 0) offset;
      Alcotest.(check (option int)) "valid limit" (Some 10) limit
  | _ -> Alcotest.fail "Expected Ok for valid query");
  
  (* Valid: None offset and limit *)
  (match validate_query query None None with
  | Ok (offset, limit) ->
      Alcotest.(check (option int)) "none offset" None offset;
      Alcotest.(check (option int)) "none limit" None limit
  | _ -> Alcotest.fail "Expected Ok for None values");
  
  (* Invalid: negative offset *)
  (match validate_query query (Some (-5)) (Some 10) with
  | Error (InvalidOffset n) ->
      Alcotest.(check int) "negative offset caught" (-5) n
  | _ -> Alcotest.fail "Expected InvalidOffset");
  
  (* Invalid: zero limit *)
  (match validate_query query (Some 0) (Some 0) with
  | Error (InvalidLimit n) ->
      Alcotest.(check int) "zero limit caught" 0 n
  | _ -> Alcotest.fail "Expected InvalidLimit");
  
  (* Invalid: negative limit *)
  (match validate_query query (Some 0) (Some (-10)) with
  | Error (InvalidLimit n) ->
      Alcotest.(check int) "negative limit caught" (-10) n
  | _ -> Alcotest.fail "Expected InvalidLimit for negative");
  
  (* Invalid: duplicate predicates (Cartesian product) *)
  let query_dup = {
    Beingdb.Query_parser.patterns = [
      { name = "artist"; args = [Var "A1"] };
      { name = "artist"; args = [Var "A2"] };
    ];
    variables = ["A1"; "A2"];
  } in
  (match validate_query query_dup (Some 0) (Some 10) with
  | Error CartesianProduct ->
      Alcotest.(check bool) "cartesian product detected" true true
  | _ -> Alcotest.fail "Expected CartesianProduct error");
  
  (* Valid: unique predicates in join *)
  let query_join = {
    Beingdb.Query_parser.patterns = [
      { name = "created"; args = [Var "A"; Var "W"] };
      { name = "shown_in"; args = [Var "W"; Var "E"] };
    ];
    variables = ["A"; "W"; "E"];
  } in
  (match validate_query query_join (Some 5) (Some 20) with
  | Ok (offset, limit) ->
      Alcotest.(check (option int)) "join offset" (Some 5) offset;
      Alcotest.(check (option int)) "join limit" (Some 20) limit
  | _ -> Alcotest.fail "Expected Ok for valid join query")

let test_query_safety_config () =
  let open Beingdb.Query_safety.Config in
  
  (* Sanity checks on configuration values *)
  Alcotest.(check bool) "timeout positive" true (query_timeout > 0.0);
  Alcotest.(check bool) "timeout reasonable" true (query_timeout < 10.0);
  Alcotest.(check bool) "max results positive" true (max_intermediate_results > 0);
  Alcotest.(check bool) "max results reasonable" true 
    (max_intermediate_results > 100 && max_intermediate_results < 100_000)

let test_query_safety_errors () =
  let open Beingdb.Query_safety in
  
  (* Test error messages are non-empty and descriptive *)
  let msg1 = error_message (InvalidOffset (-5)) in
  Alcotest.(check bool) "InvalidOffset message exists" true (String.length msg1 > 0);
  
  let msg2 = error_message (InvalidLimit 0) in
  Alcotest.(check bool) "InvalidLimit message exists" true (String.length msg2 > 0);
  
  let msg3 = error_message CartesianProduct in
  Alcotest.(check bool) "CartesianProduct message exists" true (String.length msg3 > 0);
  
  let msg4 = error_message InvalidSyntax in
  Alcotest.(check bool) "InvalidSyntax message exists" true (String.length msg4 > 0);
  
  let msg5 = error_message (InvalidPredicateName "bad-name") in
  Alcotest.(check bool) "InvalidPredicateName message exists" true (String.length msg5 > 0);
  
  let msg6 = error_message (InvalidPredicateName "") in
  Alcotest.(check bool) "InvalidPredicateName empty message exists" true (String.length msg6 > 0)

let test_predicate_name_validation () =
  let open Beingdb.Query_safety in
  
  (* Valid predicate names *)
  let valid_query_simple = {
    Beingdb.Query_parser.patterns = [
      { name = "artist"; args = [Var "A"] };
    ];
    variables = ["A"];
  } in
  (match validate_query valid_query_simple (Some 0) (Some 10) with
  | Ok _ -> Alcotest.(check bool) "simple name valid" true true
  | _ -> Alcotest.fail "Expected Ok for simple predicate name");
  
  (* Valid with numbers *)
  let valid_query_numbers = {
    Beingdb.Query_parser.patterns = [
      { name = "work_2024"; args = [Var "W"] };
    ];
    variables = ["W"];
  } in
  (match validate_query valid_query_numbers (Some 0) (Some 10) with
  | Ok _ -> Alcotest.(check bool) "name with numbers valid" true true
  | _ -> Alcotest.fail "Expected Ok for predicate name with numbers");
  
  (* Valid with underscores *)
  let valid_query_underscores = {
    Beingdb.Query_parser.patterns = [
      { name = "associated_with_location"; args = [Var "A"; Var "L"] };
    ];
    variables = ["A"; "L"];
  } in
  (match validate_query valid_query_underscores (Some 0) (Some 10) with
  | Ok _ -> Alcotest.(check bool) "name with underscores valid" true true
  | _ -> Alcotest.fail "Expected Ok for predicate name with underscores");
  
  (* Invalid: uppercase letters *)
  let invalid_query_uppercase = {
    Beingdb.Query_parser.patterns = [
      { name = "Artist"; args = [Var "A"] };
    ];
    variables = ["A"];
  } in
  (match validate_query invalid_query_uppercase (Some 0) (Some 10) with
  | Error (InvalidPredicateName name) ->
      Alcotest.(check string) "uppercase rejected" "Artist" name
  | _ -> Alcotest.fail "Expected InvalidPredicateName for uppercase");
  
  (* Invalid: special characters (dash) *)
  let invalid_query_dash = {
    Beingdb.Query_parser.patterns = [
      { name = "created-by"; args = [Var "A"; Var "W"] };
    ];
    variables = ["A"; "W"];
  } in
  (match validate_query invalid_query_dash (Some 0) (Some 10) with
  | Error (InvalidPredicateName name) ->
      Alcotest.(check string) "dash rejected" "created-by" name
  | _ -> Alcotest.fail "Expected InvalidPredicateName for dash");
  
  (* Invalid: parentheses (OR attempt) *)
  let invalid_query_parens = {
    Beingdb.Query_parser.patterns = [
      { name = "(L = paris; L = france)"; args = [] };
    ];
    variables = ["L"];
  } in
  (match validate_query invalid_query_parens (Some 0) (Some 10) with
  | Error (InvalidPredicateName _) ->
      Alcotest.(check bool) "parentheses rejected" true true
  | _ -> Alcotest.fail "Expected InvalidPredicateName for parentheses");
  
  (* Invalid: empty name *)
  let invalid_query_empty = {
    Beingdb.Query_parser.patterns = [
      { name = ""; args = [Var "X"] };
    ];
    variables = ["X"];
  } in
  (match validate_query invalid_query_empty (Some 0) (Some 10) with
  | Error (InvalidPredicateName name) ->
      Alcotest.(check string) "empty name rejected" "" name
  | _ -> Alcotest.fail "Expected InvalidPredicateName for empty name");
  
  (* Invalid: pipe character (OR attempt) *)
  let invalid_query_pipe = {
    Beingdb.Query_parser.patterns = [
      { name = "location|venue"; args = [Var "L"] };
    ];
    variables = ["L"];
  } in
  (match validate_query invalid_query_pipe (Some 0) (Some 10) with
  | Error (InvalidPredicateName name) ->
      Alcotest.(check string) "pipe rejected" "location|venue" name
  | _ -> Alcotest.fail "Expected InvalidPredicateName for pipe");
  
  (* Valid predicates, one invalid - should fail *)
  let invalid_query_mixed = {
    Beingdb.Query_parser.patterns = [
      { name = "artist"; args = [Var "A"] };
      { name = "bad-name"; args = [Var "W"] };
    ];
    variables = ["A"; "W"];
  } in
  (match validate_query invalid_query_mixed (Some 0) (Some 10) with
  | Error (InvalidPredicateName name) ->
      Alcotest.(check string) "mixed query fails on bad predicate" "bad-name" name
  | _ -> Alcotest.fail "Expected InvalidPredicateName for mixed query")

let test_encode_decode_basic () =
  let open Beingdb.Types in
  let args = [Atom "alice"; Atom "bob"; Atom "charlie"] in
  let (encoded, value_opt) = Beingdb.Pack_backend.encode_args_typed args in
  let decoded = Beingdb.Pack_backend.decode_args_typed encoded value_opt in
  Alcotest.(check arg_value_list_testable)
    "encode/decode round-trip"
    args
    decoded

let test_special_characters () =
  let open Beingdb.Types in
  (* Test colons in arguments - atoms can contain colons *)
  let args_with_colons = [Atom "alice:admin"; Atom "project:x"; Atom "role:owner"] in
  let (encoded, value_opt) = Beingdb.Pack_backend.encode_args_typed args_with_colons in
  let decoded = Beingdb.Pack_backend.decode_args_typed encoded value_opt in
  Alcotest.(check arg_value_list_testable)
    "encode/decode with colons"
    args_with_colons
    decoded;
  
  (* Test quotes in strings *)
  let args_with_quotes = [String "say \"hello\""; Atom "world"] in
  let (encoded2, value_opt2) = Beingdb.Pack_backend.encode_args_typed args_with_quotes in
  let decoded2 = Beingdb.Pack_backend.decode_args_typed encoded2 value_opt2 in
  Alcotest.(check arg_value_list_testable)
    "encode/decode with quotes"
    args_with_quotes
    decoded2;
  
  (* Test newlines and special chars in strings *)
  let args_with_special = [String "line1\nline2"; String "tab\there"; String "emoji😀"] in
  let (encoded3, value_opt3) = Beingdb.Pack_backend.encode_args_typed args_with_special in
  let decoded3 = Beingdb.Pack_backend.decode_args_typed encoded3 value_opt3 in
  Alcotest.(check arg_value_list_testable)
    "encode/decode with special chars"
    args_with_special
    decoded3

let test_edge_cases () =
  let open Beingdb.Types in
  (* Empty atoms *)
  let empty = [Atom ""; Atom ""; Atom ""] in
  let (encoded1, value_opt1) = Beingdb.Pack_backend.encode_args_typed empty in
  let decoded1 = Beingdb.Pack_backend.decode_args_typed encoded1 value_opt1 in
  Alcotest.(check arg_value_list_testable)
    "encode/decode empty strings"
    empty
    decoded1;
  
  (* Single argument *)
  let single = [Atom "alone"] in
  let (encoded2, value_opt2) = Beingdb.Pack_backend.encode_args_typed single in
  let decoded2 = Beingdb.Pack_backend.decode_args_typed encoded2 value_opt2 in
  Alcotest.(check arg_value_list_testable)
    "encode/decode single arg"
    single
    decoded2;
  
  (* Very long string *)
  let long_arg = String.make 10000 'x' in
  let long = [String long_arg; Atom "short"] in
  let (encoded3, value_opt3) = Beingdb.Pack_backend.encode_args_typed long in
  let decoded3 = Beingdb.Pack_backend.decode_args_typed encoded3 value_opt3 in
  Alcotest.(check arg_value_list_testable)
    "encode/decode very long arg"
    long
    decoded3

let test_high_arity () =
  Lwt_main.run begin
    let test_dir = Filename.temp_file "beingdb_arity_" "" in
    Unix.unlink test_dir;
    Unix.mkdir test_dir 0o755;
    
    Beingdb.Pack_backend.init ~fresh:true test_dir
    >>= fun store ->
    
    (* Test arity 5 *)
    let args5 = atoms ["a"; "b"; "c"; "d"; "e"] in
    Beingdb.Pack_backend.write_fact store "test5" args5
    >>= fun () ->
    
    Beingdb.Pack_backend.query_predicate store "test5" (atoms ["_"; "_"; "_"; "_"; "_"])
    >>= fun results ->
    Alcotest.(check int) "arity 5 stored" 1 (List.length results);
    Alcotest.(check (list arg_value_list_testable)) "arity 5 matches" [args5] results;
    
    (* Test arity 10 *)
    let args10 = atoms ["1"; "2"; "3"; "4"; "5"; "6"; "7"; "8"; "9"; "10"] in
    Beingdb.Pack_backend.write_fact store "test10" args10
    >>= fun () ->
    
    Beingdb.Pack_backend.query_predicate store "test10" 
      (atoms ["_"; "_"; "_"; "_"; "_"; "_"; "_"; "_"; "_"; "_"])
    >>= fun results10 ->
    Alcotest.(check int) "arity 10 stored" 1 (List.length results10);
    
    (* Test pattern matching on arity 5 (3rd position) *)
    Beingdb.Pack_backend.write_fact store "test5" (atoms ["x"; "y"; "target"; "z"; "w"])
    >>= fun () ->
    
    Beingdb.Pack_backend.query_predicate store "test5" (atoms ["_"; "_"; "target"; "_"; "_"])
    >>= fun pattern_results ->
    Alcotest.(check int) "pattern on arity 5" 1 (List.length pattern_results);
    
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  end

let test_pagination_overflow () =
  Lwt_main.run begin
    let test_dir = Filename.temp_file "beingdb_overflow_" "" in
    Unix.unlink test_dir;
    Unix.mkdir test_dir 0o755;
    
    Beingdb.Pack_backend.init ~fresh:true test_dir
    >>= fun store ->
    
    (* Write 10 facts *)
    let rec write_facts n =
      if n <= 0 then Lwt.return ()
      else
        Beingdb.Pack_backend.write_fact store "data" (atoms [string_of_int n])
        >>= fun () -> write_facts (n - 1)
    in
    write_facts 10
    >>= fun () ->
    
    (* Test with very large limit (should not overflow) *)
    Beingdb.Pack_backend.query_predicate store "data" ~offset:5 ~limit:max_int (atoms ["_"])
    >>= fun results ->
    Alcotest.(check int) "large limit doesn't overflow" 5 (List.length results);
    
    (* Test offset near end *)
    Beingdb.Pack_backend.query_predicate store "data" ~offset:9 ~limit:100 (atoms ["_"])
    >>= fun results2 ->
    Alcotest.(check int) "offset near end" 1 (List.length results2);
    
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  end

let test_typed_encoding_atoms () =
  let open Beingdb.Types in
  (* Test pure atoms (should stay in path) *)
  let args = [Atom "alice"; Atom "bob"; Atom "project_x"] in
  let (encoded, value_opt) = Beingdb.Pack_backend.encode_args_typed args in
  
  Alcotest.(check (option string)) "atoms have no value" None value_opt;
  
  let decoded = Beingdb.Pack_backend.decode_args_typed encoded value_opt in
  Alcotest.(check arg_value_list_testable) "atoms round-trip" args decoded

let test_typed_encoding_strings () =
  let open Beingdb.Types in
  (* Test pure strings (should go to value) *)
  let args = [Atom "id123"; String "Long text\nwith newlines"; String "More\ttext"] in
  let (encoded, value_opt) = Beingdb.Pack_backend.encode_args_typed args in
  
  Alcotest.(check bool) "strings have value" true (Option.is_some value_opt);
  
  let decoded = Beingdb.Pack_backend.decode_args_typed encoded value_opt in
  Alcotest.(check arg_value_list_testable) "strings round-trip" args decoded

let test_typed_encoding_mixed () =
  let open Beingdb.Types in
  (* Test mixed atoms and strings *)
  let args = [Atom "alice"; String "Short bio\nwith newline"; Atom "bob"; String "Another\nlong text"] in
  let (encoded, value_opt) = Beingdb.Pack_backend.encode_args_typed args in
  
  Alcotest.(check bool) "mixed has value" true (Option.is_some value_opt);
  
  let decoded = Beingdb.Pack_backend.decode_args_typed encoded value_opt in
  Alcotest.(check arg_value_list_testable) "mixed round-trip" args decoded;
  
  (* Verify encoding structure: contains atoms inline *)
  let has_substring str sub =
    try ignore (Str.search_forward (Str.regexp_string sub) str 0); true
    with Not_found -> false
  in
  Alcotest.(check bool) "contains alice" true (has_substring encoded "alice");
  Alcotest.(check bool) "contains bob" true (has_substring encoded "bob");
  Alcotest.(check bool) "contains placeholder" true (has_substring encoded "$:")

let test_typed_encoding_attack_patterns () =
  let open Beingdb.Types in
  (* Test atoms that look like encoding patterns *)
  let tricky_atoms = [Atom "5:alice"; Atom "$:0"; Atom "999:fake"; Atom "3:$:0"] in
  let (encoded, value_opt) = Beingdb.Pack_backend.encode_args_typed tricky_atoms in
  
  Alcotest.(check (option string)) "tricky atoms have no value" None value_opt;
  
  let decoded = Beingdb.Pack_backend.decode_args_typed encoded value_opt in
  Alcotest.(check arg_value_list_testable) "tricky atoms round-trip" tricky_atoms decoded

let test_typed_encoding_special_chars () =
  let open Beingdb.Types in
  (* Test various special characters in atoms and strings *)
  let args = [
    Atom "alice:admin";      (* colon in atom *)
    Atom "role:owner";       (* another colon *)
    Atom "emoji😀";          (* unicode *)
    String "Quote \"test\""; (* quotes in string *)
    String "tab\there";      (* tab in string *)
  ] in
  let (encoded, value_opt) = Beingdb.Pack_backend.encode_args_typed args in
  
  let decoded = Beingdb.Pack_backend.decode_args_typed encoded value_opt in
  Alcotest.(check arg_value_list_testable) "special chars round-trip" args decoded

let test_typed_encoding_empty_and_long () =
  let open Beingdb.Types in
  (* Test empty strings and very long arguments *)
  let long_text = String.make 5000 'x' in  (* 5KB string *)
  let args = [Atom ""; Atom "short"; String long_text; Atom ""] in
  let (encoded, value_opt) = Beingdb.Pack_backend.encode_args_typed args in
  
  let decoded = Beingdb.Pack_backend.decode_args_typed encoded value_opt in
  Alcotest.(check arg_value_list_testable) "empty and long round-trip" args decoded;
  match List.nth decoded 2 with
  | String text -> Alcotest.(check int) "long text preserved" (String.length long_text) (String.length text)
  | _ -> Alcotest.fail "Expected String type"

let test_typed_encoding_single_arg () =
  let open Beingdb.Types in
  (* Test single argument cases *)
  let single_atom = [Atom "alice"] in
  let (enc1, val1) = Beingdb.Pack_backend.encode_args_typed single_atom in
  let dec1 = Beingdb.Pack_backend.decode_args_typed enc1 val1 in
  Alcotest.(check arg_value_list_testable) "single atom" single_atom dec1;
  
  let single_string = [String "Long text\nwith newline"] in
  let (enc2, val2) = Beingdb.Pack_backend.encode_args_typed single_string in
  let dec2 = Beingdb.Pack_backend.decode_args_typed enc2 val2 in
  Alcotest.(check arg_value_list_testable) "single string" single_string dec2

let test_typed_encoding_integration () =
  let open Beingdb.Types in
  (* Integration test with actual pack backend *)
  Lwt_main.run begin
    let test_dir = Filename.temp_file "beingdb_typed_" "" in
    Unix.unlink test_dir;
    Unix.mkdir test_dir 0o755;
    
    Beingdb.Pack_backend.init ~fresh:true test_dir
    >>= fun store ->
    
    (* Write fact with mixed atoms and strings *)
    let args = [Atom "doc123"; String "Title of document"; Atom "alice"; String "Long body\nwith multiple\nlines of text"] in
    Beingdb.Pack_backend.write_fact store "document" args
    >>= fun () ->
    
    (* Query back *)
    Beingdb.Pack_backend.query_predicate store "document" [Atom "_"; Atom "_"; Atom "_"; Atom "_"]
    >>= fun results ->
    
    Alcotest.(check int) "typed encoding stored" 1 (List.length results);
    Alcotest.(check (list arg_value_list_testable)) "typed encoding retrieved" [args] results;
    
    (* Test pattern matching still works *)
    Beingdb.Pack_backend.query_predicate store "document" [Atom "doc123"; Atom "_"; Atom "_"; Atom "_"]
    >>= fun pattern_results ->
    
    Alcotest.(check int) "pattern match on typed" 1 (List.length pattern_results);
    
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  end

let test_typed_encoding_security () =
  (* Test that malicious inputs don't break decoding *)
  
  (* Negative length should be rejected *)
  let malicious1 = "-5:alice:3:bob" in
  let decoded1 = Beingdb.Pack_backend.decode_args_typed malicious1 None in
  Alcotest.(check bool) "negative length rejected" true (List.length decoded1 = 0);
  
  (* Huge length should be rejected *)
  let malicious2 = "999999999:x:3:bob" in
  let decoded2 = Beingdb.Pack_backend.decode_args_typed malicious2 None in
  Alcotest.(check bool) "huge length rejected" true (List.length decoded2 = 0);
  
  (* Out of bounds length *)
  let malicious3 = "100:short" in  (* claims 100 bytes but only has 5 *)
  let decoded3 = Beingdb.Pack_backend.decode_args_typed malicious3 None in
  Alcotest.(check bool) "out of bounds rejected" true (List.length decoded3 = 0);
  
  (* Invalid placeholder index *)
  let malicious4 = "5:alice:$:99" in
  let decoded4 = Beingdb.Pack_backend.decode_args_typed malicious4 (Some "text") in
  (* Should keep $:99 as-is since index 99 doesn't exist, treating it as Atom *)
  Alcotest.(check bool) "invalid placeholder kept" true 
    (List.mem (Beingdb.Types.Atom "$:99") decoded4)

let () =
  Alcotest.run "BeingDB" [
    "Parse", [
      Alcotest.test_case "parse_fact" `Quick test_parse_fact;
    ];
    "Git Backend", [
      Alcotest.test_case "read/write" `Quick test_git_backend;
    ];
    "Pack Backend", [
      Alcotest.test_case "query" `Quick test_pack_backend;
    ];
    "Query Engine", [
      Alcotest.test_case "joins and patterns" `Quick test_query_engine;
    ];
    "Pagination", [
      Alcotest.test_case "offset and limit" `Quick test_pagination;
    ];
    "Arity Validation", [
      Alcotest.test_case "detect mixed arities" `Quick test_arity_validation;
    ];
    "Query Safety", [
      Alcotest.test_case "validation" `Quick test_query_safety_validation;
      Alcotest.test_case "configuration values" `Quick test_query_safety_config;
      Alcotest.test_case "error messages" `Quick test_query_safety_errors;
      Alcotest.test_case "predicate name validation" `Quick test_predicate_name_validation;
    ];
    "Encoding", [
      Alcotest.test_case "basic round-trip" `Quick test_encode_decode_basic;
      Alcotest.test_case "special characters" `Quick test_special_characters;
      Alcotest.test_case "edge cases" `Quick test_edge_cases;
    ];
    "High Arity", [
      Alcotest.test_case "arity 5 and 10" `Quick test_high_arity;
    ];
    "Pagination Edge Cases", [
      Alcotest.test_case "overflow protection" `Quick test_pagination_overflow;
    ];
    "Type-Aware Encoding", [
      Alcotest.test_case "pure atoms" `Quick test_typed_encoding_atoms;
      Alcotest.test_case "pure strings" `Quick test_typed_encoding_strings;
      Alcotest.test_case "mixed atoms and strings" `Quick test_typed_encoding_mixed;
      Alcotest.test_case "attack patterns" `Quick test_typed_encoding_attack_patterns;
      Alcotest.test_case "special characters" `Quick test_typed_encoding_special_chars;
      Alcotest.test_case "empty and long args" `Quick test_typed_encoding_empty_and_long;
      Alcotest.test_case "single argument" `Quick test_typed_encoding_single_arg;
      Alcotest.test_case "integration test" `Quick test_typed_encoding_integration;
      Alcotest.test_case "security validation" `Quick test_typed_encoding_security;
    ];
  ]
