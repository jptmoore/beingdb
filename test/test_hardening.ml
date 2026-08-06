(** Tests for the "Expressive Query Hardening" pass: integer/year
    comparison semantics, connectivity-based (not blanket
    duplicate-predicate) validation, normalized error envelopes, SHA-256
    environment fingerprints, structured explain plans, stable
    optional-binding JSON, and the shared REPL/server query-environment
    lifecycle. *)

open Lwt.Syntax
open Beingdb

let create_test_pack name =
  let test_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "beingdb_hardening_test_%s_%d_%d" name (Unix.getpid ()) (Random.bits ()))
  in
  (try Unix.rmdir test_dir with _ -> ());
  Unix.mkdir test_dir 0o755;
  test_dir

let cleanup test_dir =
  let _ = Unix.system (Printf.sprintf "rm -rf %s" (Filename.quote test_dir)) in
  ()

let mkdate y m d = match Value.make_date ~year:y ~month:m ~day:d with Ok v -> v | Error e -> failwith e
let mkinstant s = match Calendar.parse_instant s with Ok t -> Value.Instant t | Error e -> failwith e

let sample_facts =
  [
    Fact.make "parent" [ Value.Atom "alice"; Value.Atom "bob" ];
    Fact.make "parent" [ Value.Atom "bob"; Value.Atom "carol" ];
    Fact.make "person" [ Value.Atom "p1" ];
    Fact.make "organisation" [ Value.Atom "o1" ];
    Fact.make "works_for" [ Value.Atom "p1"; Value.Atom "o1" ];
    Fact.make "birth_year" [ Value.Atom "alice"; Value.Year 1970 ];
    Fact.make "opened" [ Value.Atom "w1"; mkdate 2020 1 1 ];
    Fact.make "captured_at" [ Value.Atom "c1"; mkinstant "2020-01-01T00:00:00Z" ];
    Fact.make "nickname" [ Value.Atom "alice"; Value.String "Al" ];
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

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
    go 0

let run_dsl ~action store text = Controller.run_query ~max_results:100 ~language:"dsl" ?action store text ~offset:None ~limit:None
let run_core ~action store text = Controller.run_query ~max_results:100 ~language:"core" ?action store text ~offset:None ~limit:None

let expect_success outcome f =
  match outcome with
  | Controller.Success json -> f json
  | Controller.Invalid j -> Alcotest.failf "expected Success, got Invalid: %s" (Yojson.Safe.to_string j)
  | Controller.Failure { code; message } -> Alcotest.failf "expected Success, got Failure [%s]: %s" code message

let expect_invalid outcome f =
  match outcome with
  | Controller.Invalid json -> f json
  | Controller.Success j -> Alcotest.failf "expected Invalid, got Success: %s" (Yojson.Safe.to_string j)
  | Controller.Failure { code; message } -> Alcotest.failf "expected Invalid, got Failure [%s]: %s" code message

let result_count json = Yojson.Safe.Util.(json |> member "results" |> to_list |> List.length)
let errors_of json = Yojson.Safe.Util.(json |> member "errors" |> to_list)
let error_codes json = List.map (fun e -> Yojson.Safe.Util.(e |> member "code" |> to_string)) (errors_of json)

(* --- 1. integer/year comparison semantics --- *)

let test_integer_year_unequal () =
  with_pack "int_year_unequal" (fun store ->
      let* outcome = run_dsl ~action:None store "find X\nwhere\n  birth_year(X, Y)\n  Y = 1970\n" in
      expect_success outcome (fun json -> Alcotest.(check int) "integer 1970 never equals year 1970" 0 (result_count json));
      Lwt.return_unit)

let test_integer_to_year_ordered () =
  with_pack "int_to_year" (fun store ->
      let* outcome = run_dsl ~action:None store "find X\nwhere\n  birth_year(X, Y)\n  Y >= 1970\n" in
      expect_success outcome (fun json -> Alcotest.(check int) "Year >= integer literal" 1 (result_count json));
      Lwt.return_unit)

let test_year_to_integer_ordered () =
  with_pack "year_to_int" (fun store ->
      let* outcome = run_dsl ~action:None store "find X\nwhere\n  birth_year(X, Y)\n  1960 <= Y\n" in
      expect_success outcome (fun json -> Alcotest.(check int) "integer literal <= Year" 1 (result_count json));
      Lwt.return_unit)

let test_date_integer_mismatch () =
  with_pack "date_int_mismatch" (fun store ->
      let* outcome = run_dsl ~action:(Some "validate") store "find X\nwhere\n  opened(X, D)\n  D >= 1970\n" in
      expect_invalid outcome (fun json ->
          Alcotest.(check bool) "has comparison_type_mismatch" true (List.mem "comparison_type_mismatch" (error_codes json));
          let err = List.find (fun e -> Yojson.Safe.Util.(e |> member "code" |> to_string) = "comparison_type_mismatch") (errors_of json) in
          Alcotest.(check string) "leftType date" "date" Yojson.Safe.Util.(err |> member "leftType" |> to_string);
          Alcotest.(check string) "rightType integer" "integer" Yojson.Safe.Util.(err |> member "rightType" |> to_string));
      Lwt.return_unit)

let test_instant_year_mismatch () =
  with_pack "instant_year_mismatch" (fun store ->
      let* outcome = run_dsl ~action:(Some "validate") store "find X\nwhere\n  captured_at(X, T)\n  T >= @1970\n" in
      expect_invalid outcome (fun json ->
          Alcotest.(check bool) "has comparison_type_mismatch" true (List.mem "comparison_type_mismatch" (error_codes json));
          let err = List.find (fun e -> Yojson.Safe.Util.(e |> member "code" |> to_string) = "comparison_type_mismatch") (errors_of json) in
          Alcotest.(check string) "leftType instant" "instant" Yojson.Safe.Util.(err |> member "leftType" |> to_string);
          Alcotest.(check string) "rightType year" "year" Yojson.Safe.Util.(err |> member "rightType" |> to_string));
      Lwt.return_unit)

let test_core_dsl_semantic_parity () =
  with_pack "core_dsl_parity" (fun store ->
      let* core_outcome = run_core ~action:None store "birth_year(X, Y), Y >= 1970" in
      let* dsl_outcome = run_dsl ~action:None store "find X\nwhere\n  birth_year(X, Y)\n  Y >= 1970\n" in
      expect_success core_outcome (fun core_json ->
          expect_success dsl_outcome (fun dsl_json -> Alcotest.(check int) "same result count" (result_count core_json) (result_count dsl_json)));
      Lwt.return_unit)

(* --- 2. connectivity (replaces blanket duplicate-predicate rejection) --- *)

let test_valid_self_join () =
  with_pack "valid_self_join" (fun store ->
      let* outcome = run_dsl ~action:None store "find Person, Grandparent\nwhere\n  parent(Person, Parent)\n  parent(Parent, Grandparent)\n" in
      expect_success outcome (fun json -> Alcotest.(check int) "alice/bob/carol chain" 1 (result_count json));
      Lwt.return_unit)

let test_valid_multi_hop_join () =
  with_pack "valid_multi_hop" (fun store ->
      let* outcome = run_dsl ~action:None store "find P, O\nwhere\n  person(P)\n  works_for(P, O)\n  organisation(O)\n" in
      expect_success outcome (fun json -> Alcotest.(check int) "p1 works_for o1" 1 (result_count json));
      Lwt.return_unit)

let test_invalid_disconnected_query () =
  with_pack "invalid_disconnected" (fun store ->
      let* outcome = run_dsl ~action:(Some "validate") store "find P, O\nwhere\n  person(P)\n  organisation(O)\n" in
      expect_invalid outcome (fun json ->
          Alcotest.(check bool) "has disconnected_query" true (List.mem "disconnected_query" (error_codes json));
          let err = List.find (fun e -> Yojson.Safe.Util.(e |> member "code" |> to_string) = "disconnected_query") (errors_of json) in
          let groups = Yojson.Safe.Util.(err |> member "groups" |> to_list) in
          Alcotest.(check int) "two disconnected groups" 2 (List.length groups));
      Lwt.return_unit)

let test_repeated_predicate_still_flags_when_disconnected () =
  (* Same predicate twice with no shared variable/constant must still be
     rejected -- connectivity, not predicate identity, is what matters. *)
  with_pack "repeated_pred_disconnected" (fun store ->
      let* outcome = run_dsl ~action:(Some "validate") store "find A, B\nwhere\n  person(A)\n  parent(B, B)\n" in
      expect_invalid outcome (fun json -> Alcotest.(check bool) "still disconnected" true (List.mem "disconnected_query" (error_codes json)));
      Lwt.return_unit)

let test_optional_group_connected_to_outer () =
  with_pack "optional_connected" (fun store ->
      let* outcome = run_dsl ~action:None store "find X, N\nwhere\n  person(X)\n  optional\n    nickname(X, N)\n" in
      expect_success outcome (fun json -> Alcotest.(check int) "p1 has no nickname but still a row" 1 (result_count json));
      Lwt.return_unit)

let test_alternatives_branch_internally_disconnected () =
  with_pack "alt_branch_disconnected" (fun store ->
      let text = "find A\nwhere\n  either\n    person(A)\n    organisation(B)\n  or\n    parent(A, A)\n" in
      let* outcome = run_dsl ~action:(Some "validate") store text in
      expect_invalid outcome (fun json -> Alcotest.(check bool) "branch itself disconnected" true (List.mem "disconnected_query" (error_codes json)));
      Lwt.return_unit)

let test_alternatives_branches_independently_connected () =
  with_pack "alt_branches_connected" (fun store ->
      let text = "find A, C\nwhere\n  either\n    person(A)\n    works_for(A, C)\n  or\n    organisation(C)\n" in
      let* outcome = run_dsl ~action:None store text in
      expect_success outcome (fun _ -> ());
      Lwt.return_unit)

let test_negation_using_bound_outer_variable () =
  with_pack "negation_connected" (fun store ->
      let* outcome = run_dsl ~action:None store "find X\nwhere\n  person(X)\n  not\n    organisation(X)\n" in
      expect_success outcome (fun json -> Alcotest.(check int) "p1 is not an organisation" 1 (result_count json));
      Lwt.return_unit)

(* --- 3. normalized error envelope --- *)

let test_validate_envelope_shape () =
  with_pack "validate_envelope" (fun store ->
      let* outcome = run_dsl ~action:(Some "validate") store "find X\nwhere\n  person(X)\n" in
      expect_success outcome (fun json ->
          Alcotest.(check bool) "valid true" true Yojson.Safe.Util.(json |> member "valid" |> to_bool);
          Alcotest.(check string) "language dsl" "dsl" Yojson.Safe.Util.(json |> member "language" |> to_string);
          Alcotest.(check string) "languageVersion present" Query_environment.language_version
            Yojson.Safe.Util.(json |> member "languageVersion" |> to_string);
          let fp = Yojson.Safe.Util.(json |> member "environmentFingerprint" |> to_string) in
          Alcotest.(check bool) "fingerprint sha256-tagged" true (contains fp "sha256:"));
      Lwt.return_unit)

let test_core_validation_failure_is_invalid_not_failure () =
  with_pack "core_invalid_not_failure" (fun store ->
      let* outcome = run_core ~action:None store "person(A), organisation(B)" in
      (match outcome with
      | Controller.Invalid json -> Alcotest.(check bool) "valid false" false Yojson.Safe.Util.(json |> member "valid" |> to_bool)
      | Controller.Success _ -> Alcotest.fail "expected Invalid"
      | Controller.Failure { code; message } -> Alcotest.failf "expected Invalid, got Failure [%s]: %s" code message);
      Lwt.return_unit)

let test_runtime_failure_has_code () =
  with_pack "runtime_failure_code" (fun store ->
      let* outcome = Controller.run_query ~max_results:100 ~language:"sparql" store "person(X)" ~offset:None ~limit:None in
      (match outcome with
      | Controller.Failure { code; _ } -> Alcotest.(check string) "unknown_language code" "unknown_language" code
      | _ -> Alcotest.fail "expected Failure");
      Lwt.return_unit)

(* --- 4. SHA-256 environment fingerprint --- *)

let test_fingerprint_stable_across_builds () =
  with_pack "fp_stable" (fun store ->
      let* env1 = Query_environment.load_or_build store in
      let* env2 = Query_environment.load_or_build store in
      Alcotest.(check string) "stable" env1.Query_environment.fingerprint env2.Query_environment.fingerprint;
      Alcotest.(check bool) "sha256-tagged" true (contains env1.Query_environment.fingerprint "sha256:");
      Lwt.return_unit)

let test_fingerprint_changes_with_new_predicate () =
  with_pack "fp_new_predicate" (fun store ->
      let* env_before = Query_environment.load_or_build store in
      let* () = Pack_backend.write_predicate_batch store "brand_new_predicate" [ Fact.make "brand_new_predicate" [ Value.Atom "x" ] ] "add" in
      let* env_after = Query_environment.load_or_build store in
      Alcotest.(check bool) "fingerprint changed" true (env_before.Query_environment.fingerprint <> env_after.Query_environment.fingerprint);
      Lwt.return_unit)

let test_fingerprint_changes_with_new_observed_type () =
  with_pack "fp_new_type" (fun store ->
      let* env_before = Query_environment.load_or_build store in
      (* birth_year currently only has Year values at position 1; add an
         integer at that position to broaden the observed type set. *)
      let* () = Pack_backend.write_predicate_batch store "birth_year" [ Fact.make "birth_year" [ Value.Atom "bob"; Value.Integer 1975L ] ] "add" in
      let* env_after = Query_environment.load_or_build store in
      Alcotest.(check bool) "fingerprint changed" true (env_before.Query_environment.fingerprint <> env_after.Query_environment.fingerprint);
      Lwt.return_unit)

(* --- 5. structured explain plan --- *)

let test_explain_structured_plan () =
  with_pack "explain_structured" (fun store ->
      let* outcome = run_dsl ~action:(Some "explain") store "find distinct P\nwhere\n  person(P)\n  works_for(P, O)\norder by P\nlimit 5\n" in
      expect_success outcome (fun json ->
          let plan = Yojson.Safe.Util.(json |> member "plan" |> to_list) in
          let operations = List.map (fun op -> Yojson.Safe.Util.(op |> member "operation" |> to_string)) plan in
          Alcotest.(check bool) "has project" true (List.mem "project" operations);
          Alcotest.(check bool) "has distinct" true (List.mem "distinct" operations);
          Alcotest.(check bool) "has sort" true (List.mem "sort" operations);
          Alcotest.(check bool) "has limit" true (List.mem "limit" operations);
          let plan_text = Yojson.Safe.Util.(json |> member "planText" |> to_string) in
          Alcotest.(check bool) "planText non-empty" true (String.length plan_text > 0);
          let normalized = Yojson.Safe.Util.(json |> member "normalizedCoreQuery") in
          let patterns = Yojson.Safe.Util.(normalized |> member "patterns" |> to_list) in
          Alcotest.(check int) "2 normalized patterns" 2 (List.length patterns));
      Lwt.return_unit)

let test_explain_no_filesystem_paths_leaked () =
  with_pack "explain_no_paths" (fun store ->
      let* outcome = run_dsl ~action:(Some "explain") store "find P\nwhere\n  person(P)\n" in
      expect_success outcome (fun json ->
          let text = Yojson.Safe.to_string json in
          Alcotest.(check bool) "no /meta/ path" false (contains text "/meta/");
          Alcotest.(check bool) "no /index/ path" false (contains text "/index/"));
      Lwt.return_unit)

(* --- 6. stable optional-binding JSON + nulls-last ordering --- *)

let test_optional_no_match_yields_null () =
  with_pack "optional_null" (fun store ->
      let* outcome = run_dsl ~action:None store "find X, N\nwhere\n  person(X)\n  optional\n    nickname(X, N)\n" in
      expect_success outcome (fun json ->
          let rows = Yojson.Safe.Util.(json |> member "results" |> to_list) in
          let row = List.hd rows in
          let keys = Yojson.Safe.Util.keys row in
          Alcotest.(check bool) "N key present" true (List.mem "N" keys);
          Alcotest.(check bool) "N is null" true (Yojson.Safe.Util.(row |> member "N") = `Null));
      Lwt.return_unit)

let test_distinct_with_null () =
  with_pack "distinct_null" (fun store ->
      let* outcome =
        run_dsl ~action:None store "find distinct X, N\nwhere\n  person(X)\n  optional\n    nickname(X, N)\n  optional\n    nickname(X, N)\n"
      in
      expect_success outcome (fun json -> Alcotest.(check int) "one distinct row despite two optionals" 1 (result_count json));
      Lwt.return_unit)

let test_order_by_nulls_last_ascending_and_descending () =
  with_pack "order_nulls_last" (fun store ->
      let* () = Pack_backend.write_predicate_batch store "person" [ Fact.make "person" [ Value.Atom "p2" ] ] "add p2" in
      let* asc = run_dsl ~action:None store "find X, N\nwhere\n  person(X)\n  optional\n    nickname(X, N)\norder by N ascending\n" in
      let* desc = run_dsl ~action:None store "find X, N\nwhere\n  person(X)\n  optional\n    nickname(X, N)\norder by N descending\n" in
      let last_is_null outcome =
        expect_success outcome (fun json ->
            let rows = Yojson.Safe.Util.(json |> member "results" |> to_list) in
            let last = List.nth rows (List.length rows - 1) in
            Yojson.Safe.Util.(last |> member "N") = `Null)
      in
      Alcotest.(check bool) "ascending: null last" true (last_is_null asc);
      Alcotest.(check bool) "descending: null last" true (last_is_null desc);
      Lwt.return_unit)

(* --- 7. shared query-environment lifecycle (REPL vs server) --- *)

let test_repl_and_server_share_environment () =
  with_pack "shared_env" (fun store ->
      (* Simulate two independent openers of the same compiled store. *)
      let* repl_side_env = Query_environment.load_or_build store in
      let* server_side_env = Query_environment.load_or_build store in
      Alcotest.(check string) "same fingerprint" repl_side_env.Query_environment.fingerprint server_side_env.Query_environment.fingerprint;
      Alcotest.(check int) "same predicate count" (List.length repl_side_env.Query_environment.predicates)
        (List.length server_side_env.Query_environment.predicates);
      let text = "find X\nwhere\n  person(X)\n" in
      (match Dsl_parser.parse text with
      | Error e -> Alcotest.failf "parse error: %s" e
      | Ok surface ->
          let repl_result = Dsl_lower.lower repl_side_env surface in
          let server_result = Dsl_lower.lower server_side_env surface in
          (match (repl_result.Dsl_lower.core_query, server_result.Dsl_lower.core_query) with
          | Some repl_cq, Some server_cq ->
              Alcotest.(check string) "same normalized query" (Query_ast.query_to_string repl_cq.Core_query.query)
                (Query_ast.query_to_string server_cq.Core_query.query)
          | _ -> Alcotest.fail "expected both to lower successfully"));
      Lwt.return_unit)

let () =
  Alcotest.run "BeingDB Hardening"
    [
      ( "Integer/year comparison semantics",
        [
          Alcotest.test_case "integer and year remain unequal" `Quick test_integer_year_unequal;
          Alcotest.test_case "integer-to-year ordered comparison" `Quick test_integer_to_year_ordered;
          Alcotest.test_case "year-to-integer ordered comparison" `Quick test_year_to_integer_ordered;
          Alcotest.test_case "date-to-integer comparison fails" `Quick test_date_integer_mismatch;
          Alcotest.test_case "instant-to-year comparison fails" `Quick test_instant_year_mismatch;
          Alcotest.test_case "core and dsl semantic parity" `Quick test_core_dsl_semantic_parity;
        ] );
      ( "Connectivity validation",
        [
          Alcotest.test_case "valid self-join" `Quick test_valid_self_join;
          Alcotest.test_case "valid multi-hop join" `Quick test_valid_multi_hop_join;
          Alcotest.test_case "invalid disconnected query" `Quick test_invalid_disconnected_query;
          Alcotest.test_case "repeated predicate still flags when disconnected" `Quick test_repeated_predicate_still_flags_when_disconnected;
          Alcotest.test_case "optional group connected to outer" `Quick test_optional_group_connected_to_outer;
          Alcotest.test_case "alternatives branch internally disconnected" `Quick test_alternatives_branch_internally_disconnected;
          Alcotest.test_case "alternatives branches independently connected" `Quick test_alternatives_branches_independently_connected;
          Alcotest.test_case "negation using bound outer variable" `Quick test_negation_using_bound_outer_variable;
        ] );
      ( "Normalized error envelope",
        [
          Alcotest.test_case "validate envelope shape" `Quick test_validate_envelope_shape;
          Alcotest.test_case "core validation failure is Invalid not Failure" `Quick test_core_validation_failure_is_invalid_not_failure;
          Alcotest.test_case "runtime failure has code" `Quick test_runtime_failure_has_code;
        ] );
      ( "SHA-256 environment fingerprint",
        [
          Alcotest.test_case "stable across repeated builds" `Quick test_fingerprint_stable_across_builds;
          Alcotest.test_case "changes with new predicate" `Quick test_fingerprint_changes_with_new_predicate;
          Alcotest.test_case "changes with new observed type" `Quick test_fingerprint_changes_with_new_observed_type;
        ] );
      ( "Structured explain plan",
        [
          Alcotest.test_case "structured plan + planText + normalizedCoreQuery" `Quick test_explain_structured_plan;
          Alcotest.test_case "no filesystem paths leaked" `Quick test_explain_no_filesystem_paths_leaked;
        ] );
      ( "Stable optional-binding JSON",
        [
          Alcotest.test_case "optional no match yields null" `Quick test_optional_no_match_yields_null;
          Alcotest.test_case "distinct with null" `Quick test_distinct_with_null;
          Alcotest.test_case "order by nulls last (asc and desc)" `Quick test_order_by_nulls_last_ascending_and_descending;
        ] );
      ("Shared query-environment lifecycle", [ Alcotest.test_case "REPL and server share environment" `Quick test_repl_and_server_share_environment ]);
    ]
