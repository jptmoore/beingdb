(** Unit tests for BeingDB *)

open Lwt.Infix

let test_parse_fact () =
  let open Beingdb.Parse_predicate in
  
  (* Test simple fact *)
  let fact1 = "created(tina_keane, she)." in
  let result1 = parse_fact fact1 in
  Alcotest.(check (option (pair string (list string))))
    "parse simple fact" 
    (Some ("created", ["tina_keane"; "she"]))
    result1;
  
  (* Test fact without trailing dot *)
  let fact2 = "shown_in(she, rewind_exhibition_1995)" in
  let result2 = parse_fact fact2 in
  Alcotest.(check (option (pair string (list string))))
    "parse fact without dot"
    (Some ("shown_in", ["she"; "rewind_exhibition_1995"]))
    result2;
  
  (* Test fact with spaces *)
  let fact3 = "created( tina_keane , she )." in
  let result3 = parse_fact fact3 in
  Alcotest.(check (option (pair string (list string))))
    "parse fact with spaces"
    (Some ("created", ["tina_keane"; "she"]))
    result3;
  
  (* Test three-argument fact *)
  let fact4 = "relationship(subject, predicate, object)." in
  let result4 = parse_fact fact4 in
  Alcotest.(check (option (pair string (list string))))
    "parse three-argument fact"
    (Some ("relationship", ["subject"; "predicate"; "object"]))
    result4;
  
  (* Test single-argument fact *)
  let fact5 = "active(user123)." in
  let result5 = parse_fact fact5 in
  Alcotest.(check (option (pair string (list string))))
    "parse single-argument fact"
    (Some ("active", ["user123"]))
    result5;
  
  (* Test fact with quoted strings *)
  let fact6 = "keyword(doc_456, \"neural networks\")." in
  let result6 = parse_fact fact6 in
  Alcotest.(check (option (pair string (list string))))
    "parse fact with quoted string"
    (Some ("keyword", ["doc_456"; "neural networks"]))
    result6;
  
  (* Test invalid facts *)
  let fact7 = "not_a_fact" in
  let result7 = parse_fact fact7 in
  Alcotest.(check (option (pair string (list string))))
    "parse invalid fact (no parens)"
    None
    result7;
  
  (* Parser is lenient with unclosed parens - it just treats content as args *)
  let fact8 = "invalid(" in
  let result8 = parse_fact fact8 in
  Alcotest.(check (option (pair string (list string))))
    "parse fact with unclosed parens (lenient parser)"
    (Some ("invalid", []))
    result8;
  
  let fact9 = "" in
  let result9 = parse_fact fact9 in
  Alcotest.(check (option (pair string (list string))))
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
    Beingdb.Pack_backend.write_fact store "created" ["artist_a"; "work_1"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" ["artist_b"; "work_2"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" ["artist_a"; "work_3"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" ["artist_c"; "work_4"]
    >>= fun () ->
    
    (* Write facts to 'shown_in' predicate *)
    Beingdb.Pack_backend.write_fact store "shown_in" ["work_1"; "exhibition_a"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "shown_in" ["work_2"; "exhibition_b"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "shown_in" ["work_3"; "exhibition_a"]
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
    Beingdb.Pack_backend.query_predicate store "created" ["artist_a"; "_"]
    >>= fun artist_a_works ->
    
    Alcotest.(check int)
      "pack backend pattern match finds 2 works by artist_a"
      2
      (List.length artist_a_works);
    
    (* Query with pattern - find specific work *)
    Beingdb.Pack_backend.query_predicate store "created" ["_"; "work_2"]
    >>= fun work_2_facts ->
    
    Alcotest.(check int)
      "pack backend pattern match finds work_2"
      1
      (List.length work_2_facts);
    
    Alcotest.(check (list (list string)))
      "pack backend work_2 created by artist_b"
      [["artist_b"; "work_2"]]
      work_2_facts;
    
    (* Query with pattern - works shown at exhibition_a *)
    Beingdb.Pack_backend.query_predicate store "shown_in" ["_"; "exhibition_a"]
    >>= fun exhibition_a_works ->
    
    Alcotest.(check int)
      "pack backend finds 2 works at exhibition_a"
      2
      (List.length exhibition_a_works);
    
    (* Query with wildcards in both positions *)
    Beingdb.Pack_backend.query_predicate store "created" ["_"; "_"]
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
    Beingdb.Pack_backend.write_fact store "created" ["artist_a"; "work_1"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" ["artist_a"; "work_2"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" ["artist_b"; "work_3"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "shown_in" ["work_1"; "exhibition_x"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "shown_in" ["work_2"; "exhibition_y"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "shown_in" ["work_3"; "exhibition_x"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "held_at" ["exhibition_x"; "venue_london"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "held_at" ["exhibition_y"; "venue_paris"]
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
    Beingdb.Pack_backend.write_fact store "created" ["artist_1"; "work_1"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" ["artist_2"; "work_2"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" ["artist_3"; "work_3"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" ["artist_4"; "work_4"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" ["artist_5"; "work_5"]
    >>= fun () ->
    
    (* Test offset without limit *)
    Beingdb.Pack_backend.query_predicate ~offset:2 store "created" ["_"; "_"]
    >>= fun offset_results ->
    
    Alcotest.(check int)
      "pagination: offset 2 returns 3 results"
      3
      (List.length offset_results);
    
    (* Test limit without offset *)
    Beingdb.Pack_backend.query_predicate ~limit:2 store "created" ["_"; "_"]
    >>= fun limit_results ->
    
    Alcotest.(check int)
      "pagination: limit 2 returns 2 results"
      2
      (List.length limit_results);
    
    (* Test offset and limit together *)
    Beingdb.Pack_backend.query_predicate ~offset:1 ~limit:2 store "created" ["_"; "_"]
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
  Alcotest.(check bool) "InvalidSyntax message exists" true (String.length msg4 > 0)

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
    ];
  ]
