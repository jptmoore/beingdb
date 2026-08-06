(** End-to-end sanity tests for the expressive query language pipeline:
    Dsl_parser -> Query_environment -> Dsl_lower -> Query_planner /
    Query_engine -> Core_query.apply. *)

open Lwt.Syntax
open Beingdb

let create_test_pack name =
  let test_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "beingdb_dsl_test_%s_%d_%d" name (Unix.getpid ()) (Random.bits ()))
  in
  (try Unix.rmdir test_dir with _ -> ());
  Unix.mkdir test_dir 0o755;
  test_dir

let cleanup test_dir =
  let _ = Unix.system (Printf.sprintf "rm -rf %s" (Filename.quote test_dir)) in
  ()

let sample_facts =
  [
    Fact.make "created" [ Value.Atom "tina_keane"; Value.Atom "she" ];
    Fact.make "created" [ Value.Atom "lynn_hershman"; Value.Atom "lorna" ];
    Fact.make "artist" [ Value.Atom "tina_keane" ];
    Fact.make "artist" [ Value.Atom "lynn_hershman" ];
    Fact.make "birth_year" [ Value.Atom "tina_keane"; Value.Year 1951 ];
    Fact.make "birth_year" [ Value.Atom "lynn_hershman"; Value.Year 1941 ];
    Fact.make "nationality" [ Value.Atom "lynn_hershman"; Value.Atom "american" ];
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

let run_dsl store text =
  let* env = Query_environment.build store in
  match Dsl_parser.parse text with
  | Error e -> Lwt.return (Error e)
  | Ok surface -> (
      match Dsl_lower.lower env surface with
      | { errors = _ :: _ as errors; _ } -> Lwt.return (Error (String.concat "; " (List.map Validation_error.message errors)))
      | { core_query = None; _ } -> Lwt.return (Error "no core query and no errors (should not happen)")
      | { core_query = Some cq; _ } -> (
          let* result = Query_engine.execute store cq.query in
          match result with
          | Error e -> Lwt.return (Error e)
          | Ok result -> Lwt.return (Ok (Core_query.apply cq result))))

let value_string = function Some v -> Value.canonical_string v | None -> "<unbound>"

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
    go 0

(* --- Dsl_parser --- *)

let test_parse_simple () =
  match Dsl_parser.parse "find Artist\nwhere\n  artist(Artist)\n" with
  | Error e -> Alcotest.failf "parse failed: %s" e
  | Ok q ->
      Alcotest.(check (list string)) "projection" [ "Artist" ] q.projection.variables;
      Alcotest.(check bool) "not distinct" false q.projection.distinct;
      Alcotest.(check int) "one clause" 1 (List.length q.where_)

let test_parse_optional_either_not () =
  let text =
    "find Artist, Nat\n\
     where\n\
    \  artist(Artist)\n\
    \  optional\n\
    \    nationality(Artist, Nat)\n\
    \  either\n\
    \    birth_year(Artist, Y)\n\
    \  or\n\
    \    birth_year(Artist, Y)\n\
    \  not\n\
    \    created(Artist, lorna)\n\
     order by Artist ascending\n\
     limit 10\n\
     offset 0\n"
  in
  match Dsl_parser.parse text with
  | Error e -> Alcotest.failf "parse failed: %s" e
  | Ok q ->
      Alcotest.(check int) "4 top-level clauses" 4 (List.length q.where_);
      Alcotest.(check (option int)) "limit" (Some 10) q.limit;
      Alcotest.(check (option int)) "offset" (Some 0) q.offset;
      Alcotest.(check int) "one order item" 1 (List.length q.order_by)

let test_parse_error_missing_where () =
  match Dsl_parser.parse "find X\n" with Error _ -> () | Ok _ -> Alcotest.fail "expected parse error"

(* --- Dsl_lower / execution --- *)

let test_lower_unknown_predicate () =
  with_pack "unknown_pred" (fun store ->
      let* result = run_dsl store "find X\nwhere\n  artst(X)\n" in
      (match result with Error msg -> Alcotest.(check bool) "mentions unknown" true (contains msg "Unknown predicate") | Ok _ -> Alcotest.fail "expected error");
      Lwt.return_unit)

let test_lower_arity_mismatch () =
  with_pack "arity" (fun store ->
      let* result = run_dsl store "find X\nwhere\n  artist(X, X)\n" in
      (match result with
      | Error msg -> Alcotest.(check bool) "mentions arity" true (contains msg "argument")
      | Ok _ -> Alcotest.fail "expected error");
      Lwt.return_unit)

let test_lower_unbound_projection () =
  with_pack "unbound_proj" (fun store ->
      let* result = run_dsl store "find X, Y\nwhere\n  artist(X)\n" in
      (match result with Error msg -> Alcotest.(check bool) "mentions Y" true (contains msg "Y") | Ok _ -> Alcotest.fail "expected error");
      Lwt.return_unit)

let test_lower_unsafe_negation () =
  with_pack "unsafe_neg" (fun store ->
      let* result = run_dsl store "find X\nwhere\n  artist(X)\n  not\n    birth_year(Q, 1951)\n" in
      (match result with
      | Error msg -> Alcotest.(check bool) "mentions unsafe" true (contains msg "not")
      | Ok _ -> Alcotest.fail "expected error");
      Lwt.return_unit)

let test_execute_simple () =
  with_pack "exec_simple" (fun store ->
      let* result = run_dsl store "find Artist\nwhere\n  artist(Artist)\n" in
      match result with
      | Error e -> Alcotest.failf "unexpected error: %s" e
      | Ok (vars, rows) ->
          Alcotest.(check (list string)) "vars" [ "Artist" ] vars;
          Alcotest.(check int) "row count" 2 (List.length rows);
          Lwt.return_unit)

let test_execute_optional () =
  with_pack "exec_optional" (fun store ->
      let text = "find Artist, Nat\nwhere\n  artist(Artist)\n  optional\n    nationality(Artist, Nat)\n" in
      let* result = run_dsl store text in
      match result with
      | Error e -> Alcotest.failf "unexpected error: %s" e
      | Ok (_, rows) ->
          Alcotest.(check int) "row count" 2 (List.length rows);
          let has_unbound = List.exists (fun row -> List.nth row 1 = None) rows in
          Alcotest.(check bool) "one row has unbound Nat" true has_unbound;
          Lwt.return_unit)

let test_execute_not () =
  with_pack "exec_not" (fun store ->
      let text = "find Artist\nwhere\n  artist(Artist)\n  not\n    created(Artist, lorna)\n" in
      let* result = run_dsl store text in
      match result with
      | Error e -> Alcotest.failf "unexpected error: %s" e
      | Ok (_, rows) ->
          Alcotest.(check int) "only one artist not creating lorna" 1 (List.length rows);
          Lwt.return_unit)

let test_execute_either_or () =
  with_pack "exec_either" (fun store ->
      let text = "find Artist\nwhere\n  either\n    birth_year(Artist, @1951)\n  or\n    nationality(Artist, american)\n" in
      let* result = run_dsl store text in
      match result with
      | Error e -> Alcotest.failf "unexpected error: %s" e
      | Ok (_, rows) ->
          Alcotest.(check int) "both artists match one branch" 2 (List.length rows);
          Lwt.return_unit)

let test_execute_order_limit_offset () =
  with_pack "exec_order" (fun store ->
      let text = "find Artist\nwhere\n  artist(Artist)\norder by Artist descending\nlimit 1\n" in
      let* result = run_dsl store text in
      match result with
      | Error e -> Alcotest.failf "unexpected error: %s" e
      | Ok (_, rows) ->
          Alcotest.(check int) "limited to 1" 1 (List.length rows);
          Alcotest.(check string) "descending, tina_keane first" "tina_keane" (value_string (List.hd (List.hd rows)));
          Lwt.return_unit)

let test_execute_distinct () =
  with_pack "exec_distinct" (fun store ->
      let text = "find distinct Year\nwhere\n  birth_year(_, Year)\n  birth_year(_, Year)\n" in
      let* result = run_dsl store text in
      match result with
      | Error e -> Alcotest.failf "unexpected error: %s" e
      | Ok (_, rows) ->
          Alcotest.(check bool) "at most 2 distinct years" true (List.length rows <= 2);
          Lwt.return_unit)

let () =
  Alcotest.run "BeingDB Dsl"
    [
      ( "Dsl_parser",
        [
          Alcotest.test_case "simple find/where" `Quick test_parse_simple;
          Alcotest.test_case "optional/either/or/not/order/limit/offset" `Quick test_parse_optional_either_not;
          Alcotest.test_case "missing where is an error" `Quick test_parse_error_missing_where;
        ] );
      ( "Dsl_lower validation",
        [
          Alcotest.test_case "unknown predicate" `Quick test_lower_unknown_predicate;
          Alcotest.test_case "arity mismatch" `Quick test_lower_arity_mismatch;
          Alcotest.test_case "unbound projection" `Quick test_lower_unbound_projection;
          Alcotest.test_case "unsafe negation" `Quick test_lower_unsafe_negation;
        ] );
      ( "End-to-end execution",
        [
          Alcotest.test_case "simple" `Quick test_execute_simple;
          Alcotest.test_case "optional" `Quick test_execute_optional;
          Alcotest.test_case "not" `Quick test_execute_not;
          Alcotest.test_case "either/or" `Quick test_execute_either_or;
          Alcotest.test_case "order/limit/offset" `Quick test_execute_order_limit_offset;
          Alcotest.test_case "distinct" `Quick test_execute_distinct;
        ] );
    ]
