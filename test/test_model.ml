(** Unit tests for Model domain types and validation *)

open Beingdb

(** Test: make_predicate creates predicate *)
let test_make_predicate () =
  let pred = Model.make_predicate "created" 2 in
  Alcotest.(check string) "has name" "created" pred.Model.name;
  Alcotest.(check int) "has arity" 2 pred.Model.arity;
  Alcotest.(check bool) "no samples" true (pred.Model.sample_facts = None)

(** Test: make_predicate with samples *)
let test_make_predicate_with_samples () =
  let samples = [ Fact.make "test" [ Value.Atom "a"; Value.Atom "b" ] ] in
  let pred = Model.make_predicate ~samples:(Some samples) "test" 2 in
  Alcotest.(check string) "has name" "test" pred.Model.name;
  match pred.Model.sample_facts with
  | None -> Alcotest.fail "Expected samples"
  | Some s -> Alcotest.(check int) "has samples" 1 (List.length s)

(** Test: make_fact creates fact *)
let test_make_fact () =
  let fact = Model.make_fact "created" [ Value.Atom "artist"; Value.Atom "work" ] in
  Alcotest.(check string) "has predicate" "created" fact.Model.predicate;
  Alcotest.(check int) "has 2 arguments" 2 (List.length fact.Model.arguments)

(** Test: make_query_result *)
let test_make_query_result () =
  let bindings = [ [ ("X", Value.Atom "value1"); ("Y", Value.Atom "value2") ]; [ ("X", Value.Atom "value3"); ("Y", Value.Atom "value4") ] ] in
  let result = Model.make_query_result [ "X"; "Y" ] bindings 2 in
  Alcotest.(check int) "has 2 variables" 2 (List.length result.Model.variables);
  Alcotest.(check int) "has 2 bindings" 2 (List.length result.Model.bindings);
  Alcotest.(check int) "has total count" 2 result.Model.total_count

(** Test: validate_predicate_name accepts valid name *)
let test_validate_predicate_name_valid () =
  match Model.validate_predicate_name "created" with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "Valid predicate name rejected"

(** Test: validate_predicate_name rejects empty *)
let test_validate_predicate_name_empty () =
  match Model.validate_predicate_name "" with
  | Ok () -> Alcotest.fail "Empty name should be rejected"
  | Error msg -> Alcotest.(check bool) "has error message" true (String.length msg > 0)

(** Test: validate_predicate_name rejects spaces *)
let test_validate_predicate_name_spaces () =
  match Model.validate_predicate_name "has spaces" with
  | Ok () -> Alcotest.fail "Name with spaces should be rejected"
  | Error msg -> Alcotest.(check bool) "has error message" true (String.length msg > 0)

(** Test: validate_fact_arity accepts matching arity *)
let test_validate_fact_arity_valid () =
  let pred = Model.make_predicate "created" 2 in
  let fact = Model.make_fact "created" [ Value.Atom "a"; Value.Atom "b" ] in
  match Model.validate_fact_arity pred fact with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "Valid fact arity rejected"

(** Test: validate_fact_arity rejects mismatched arity *)
let test_validate_fact_arity_invalid () =
  let pred = Model.make_predicate "created" 2 in
  let fact = Model.make_fact "created" [ Value.Atom "a" ] in
  match Model.validate_fact_arity pred fact with
  | Ok () -> Alcotest.fail "Mismatched arity should be rejected"
  | Error msg -> Alcotest.(check bool) "has error message" true (String.length msg > 0)

(** Test: of_query_engine_result converts result *)
let test_of_query_engine_result () =
  let qe_result : Query_engine.result =
    {
      variables = [ "X"; "Y" ];
      bindings = [ [ ("X", Value.Atom "a"); ("Y", Value.Atom "b") ]; [ ("X", Value.Atom "c"); ("Y", Value.Atom "d") ] ];
    }
  in
  let result = Model.of_query_engine_result qe_result in
  Alcotest.(check int) "has 2 variables" 2 (List.length result.Model.variables);
  Alcotest.(check int) "has 2 bindings" 2 (List.length result.Model.bindings);
  Alcotest.(check int) "total count matches bindings" 2 result.Model.total_count

(** Helper: Create test Pack store *)
let create_test_pack name =
  let test_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "beingdb_model_data_test_%s_%d" name (Unix.getpid ()))
  in
  (try Unix.rmdir test_dir with _ -> ());
  Unix.mkdir test_dir 0o755;
  Lwt_main.run
    (let open Lwt.Syntax in
     let* store = Pack_backend.init ~fresh:true test_dir in
     let facts =
       [
         Fact.make "created" [ Value.Atom "tina_keane"; Value.Atom "she" ];
         Fact.make "created" [ Value.Atom "lynn_hershman"; Value.Atom "lorna" ];
         Fact.make "artist" [ Value.Atom "tina_keane" ];
       ]
     in
     let* () = Pack_backend.write_predicate_batch store "created" [ List.nth facts 0; List.nth facts 1 ] "compile created" in
     let* () = Pack_backend.write_predicate_batch store "artist" [ List.nth facts 2 ] "compile artist" in
     Lwt.return (store, test_dir))

let cleanup test_dir =
  let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
  let _ = Unix.system cmd in
  ()

(** Test: Model.list_predicates returns domain predicates *)
let test_model_list_predicates () =
  let store, test_dir = create_test_pack "list_predicates" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* predicates = Model.list_predicates store in
     Alcotest.(check bool) "has predicates" true (List.length predicates >= 2);
     List.iter
       (fun pred ->
         Alcotest.(check bool) "has name" true (String.length pred.Model.name > 0);
         Alcotest.(check bool) "has arity" true (pred.Model.arity > 0))
       predicates;
     cleanup test_dir;
     Lwt.return ())

(** Test: Model.list_predicates_with_samples returns predicates with samples *)
let test_model_list_predicates_with_samples () =
  let store, test_dir = create_test_pack "list_samples" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* predicates = Model.list_predicates_with_samples ~samples:5 store in
     Alcotest.(check bool) "has predicates" true (List.length predicates >= 2);
     let has_samples = List.exists (fun pred -> pred.Model.sample_facts <> None) predicates in
     Alcotest.(check bool) "at least one has samples" true has_samples;
     cleanup test_dir;
     Lwt.return ())

(** Test: Model.query_predicate returns domain facts *)
let test_model_query_predicate () =
  let store, test_dir = create_test_pack "query_pred" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* facts = Model.query_predicate ~limit:100 store "created" in
     Alcotest.(check bool) "has facts" true (List.length facts > 0);
     List.iter
       (fun (fact : Fact.t) ->
         Alcotest.(check string) "predicate name" "created" fact.predicate;
         Alcotest.(check bool) "has arguments" true (List.length fact.arguments > 0))
       facts;
     cleanup test_dir;
     Lwt.return ())

(** Test: Model.execute_query returns domain query_result *)
let test_model_execute_query () =
  let store, test_dir = create_test_pack "execute" in
  Lwt_main.run
    (let open Lwt.Syntax in
     let query = match Query_parser.parse_query "created(Artist, Work)" with Some q -> q | None -> Alcotest.fail "Query parsing failed" in
     let* result = Model.execute_query store query in
     (match result with
     | Ok r ->
         Alcotest.(check bool) "has variables" true (List.length r.Model.variables > 0);
         Alcotest.(check bool) "has bindings" true (List.length r.Model.bindings > 0);
         Alcotest.(check bool) "total_count positive" true (r.Model.total_count > 0)
     | Error e -> Alcotest.fail e);
     cleanup test_dir;
     Lwt.return ())

let () =
  Alcotest.run "BeingDB Model"
    [
      ( "Constructors",
        [
          Alcotest.test_case "make_predicate" `Quick test_make_predicate;
          Alcotest.test_case "make_predicate with samples" `Quick test_make_predicate_with_samples;
          Alcotest.test_case "make_fact" `Quick test_make_fact;
          Alcotest.test_case "make_query_result" `Quick test_make_query_result;
        ] );
      ( "Validation",
        [
          Alcotest.test_case "validate_predicate_name valid" `Quick test_validate_predicate_name_valid;
          Alcotest.test_case "validate_predicate_name empty" `Quick test_validate_predicate_name_empty;
          Alcotest.test_case "validate_predicate_name spaces" `Quick test_validate_predicate_name_spaces;
          Alcotest.test_case "validate_fact_arity valid" `Quick test_validate_fact_arity_valid;
          Alcotest.test_case "validate_fact_arity invalid" `Quick test_validate_fact_arity_invalid;
        ] );
      ("Conversion", [ Alcotest.test_case "of_query_engine_result" `Quick test_of_query_engine_result ]);
      ( "Data Access",
        [
          Alcotest.test_case "list_predicates" `Quick test_model_list_predicates;
          Alcotest.test_case "list_predicates_with_samples" `Quick test_model_list_predicates_with_samples;
          Alcotest.test_case "query_predicate" `Quick test_model_query_predicate;
          Alcotest.test_case "execute_query" `Quick test_model_execute_query;
        ] );
    ]

