(** Adapter parity: identical query fixtures executed against the native
    Irmin Pack store (written by the same writer [beingdb-compile] uses)
    and the in-memory runtime store must produce identical results,
    identical introspection, and identical environment fingerprints. A
    closed pack is also reopened read-only (as [beingdb-serve] does) and
    queried again. *)

open Lwt.Syntax
open Beingdb
module Mem_engine = Query_engine.Make (Memory_store)
module Mem_environment = Query_environment.Make (Memory_store)

let mkdate y m d = match Value.make_date ~year:y ~month:m ~day:d with Ok v -> v | Error e -> failwith e

let facts =
  [
    Fact.make "person" [ Value.Atom "alice" ];
    Fact.make "person" [ Value.Atom "bob" ];
    Fact.make "person" [ Value.Atom "carol" ];
    Fact.make "created_by" [ Value.Atom "work1"; Value.Atom "alice" ];
    Fact.make "created_by" [ Value.Atom "work2"; Value.Atom "alice" ];
    Fact.make "created_by" [ Value.Atom "work3"; Value.Atom "bob" ];
    Fact.make "born" [ Value.Atom "alice"; Value.Year 1951 ];
    Fact.make "born" [ Value.Atom "bob"; Value.Year 1941 ];
    Fact.make "born" [ Value.Atom "carol"; Value.Year 1975 ];
    Fact.make "score" [ Value.Atom "work1"; Value.Decimal (Decimal.make 92L 2) ];
    Fact.make "score" [ Value.Atom "work2"; Value.Integer 1L ];
    Fact.make "score" [ Value.Atom "work3"; Value.Decimal (Decimal.make 50L 2) ];
    Fact.make "opened" [ Value.Atom "ex1"; mkdate 2019 6 15 ];
    Fact.make "opened" [ Value.Atom "ex2"; mkdate 2020 1 1 ];
    Fact.make "exhibited_at" [ Value.Atom "work1"; Value.Atom "ex1" ];
    Fact.make "exhibited_at" [ Value.Atom "work3"; Value.Atom "ex2" ];
    Fact.make "value" [ Value.Atom "x"; Value.Integer 1979L ];
    Fact.make "value" [ Value.Atom "y"; Value.String "unknown" ];
    Fact.make "title" [ Value.Atom "work1"; Value.String "Hello, world" ];
  ]

let core_queries =
  [
    "person(X)";
    "created_by(W, alice)";
    "created_by(W, A), exhibited_at(W, E)";
    "created_by(W, A), person(A), born(A, @1941)";
    "born(P, Y), Y between 1940 and 1960";
    "born(P, Y), Y >= 1945";
    "score(W, S), S >= 0.9";
    "score(W, S), S < 1";
    "opened(E, D), D >= @2020-01-01";
    "value(K, V), V > 1900";
    "value(K, 1979)";
    "title(W, \"Hello, world\")";
    "created_by(W, A), score(W, S), S > 0.6, born(A, Y)";
    "opened(E, D), D < 1979";
  ]

let dsl_queries =
  [
    "find Artist, Work\nwhere\n  person(Artist)\n  created_by(Work, Artist)\norder by Work descending\nlimit 2\n";
    "find P, W\nwhere\n  person(P)\n  optional\n    created_by(W, P)\norder by P ascending\n";
    "find Work\nwhere\n  either\n    exhibited_at(Work, ex1)\n  or\n    exhibited_at(Work, ex2)\n";
    "find distinct A\nwhere\n  created_by(W, A)\n";
    "find P\nwhere\n  person(P)\n  not\n    created_by(_, P)\n";
    "find W, S\nwhere\n  score(W, S)\n  S >= 0.5\norder by W ascending\noffset 1\nlimit 1\n";
  ]

let create_test_pack name =
  let test_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "beingdb_parity_test_%s_%d_%d" name (Unix.getpid ()) (Random.bits ()))
  in
  (try Unix.rmdir test_dir with _ -> ());
  Unix.mkdir test_dir 0o755;
  test_dir

let cleanup test_dir =
  let _ = Unix.system (Printf.sprintf "rm -rf %s" (Filename.quote test_dir)) in
  ()

let group_by_predicate facts =
  let order = ref [] and groups = Hashtbl.create 8 in
  List.iter
    (fun (f : Fact.t) ->
      match Hashtbl.find_opt groups f.predicate with
      | Some fs -> Hashtbl.replace groups f.predicate (f :: fs)
      | None ->
          order := f.predicate :: !order;
          Hashtbl.replace groups f.predicate [ f ])
    facts;
  List.map (fun p -> (p, List.rev (Hashtbl.find groups p))) (List.rev !order)

let write_pack store =
  Lwt_list.iter_s
    (fun (p, fs) -> Pack_backend.write_predicate_batch store p fs (Printf.sprintf "compile %s" p))
    (group_by_predicate facts)

let with_native name f =
  let dir = create_test_pack name in
  Lwt_main.run
    (Lwt.finalize
       (fun () ->
         let* store = Pack_backend.init ~fresh:true dir in
         let* () = write_pack store in
         f dir store)
       (fun () ->
         cleanup dir;
         Lwt.return_unit))

let memory = Memory_store.of_facts facts

let render_result = function
  | Error _ -> [ "<error>" ]
  | Ok (r : Query_engine.result) ->
      String.concat "," r.variables
      :: List.sort String.compare
           (List.map
              (fun b -> String.concat ";" (List.map (fun (v, x) -> v ^ "=" ^ Value.type_name x ^ ":" ^ Value.canonical_string x) b))
              r.bindings)

let render_rows (vars, rows) =
  String.concat "," vars
  :: List.map
       (fun row -> String.concat "," (List.map (function Some v -> Value.type_name v ^ ":" ^ Value.canonical_string v | None -> "-") row))
       rows

let parse text = match Query_parser.parse_query_result text with Ok q -> q | Error e -> Alcotest.failf "parse error: %s" e

let lower env text =
  match Dsl_parser.parse text with
  | Error e -> Alcotest.failf "parse error: %s" e
  | Ok surface -> (
      match Dsl_lower.lower env surface with
      | { core_query = Some cq; errors = []; _ } -> cq
      | { errors; _ } -> Alcotest.failf "invalid: %s" (String.concat "; " (List.map Validation_error.message errors)))

let test_core_parity () =
  with_native "core" (fun _ native ->
      Lwt_list.iter_s
        (fun text ->
          let q = parse text in
          let* n = Query_engine.execute native q in
          let* m = Mem_engine.execute memory q in
          Alcotest.(check (list string)) text (render_result n) (render_result m);
          Lwt.return_unit)
        core_queries)

let test_dsl_parity () =
  with_native "dsl" (fun _ native ->
      let* native_env = Query_environment.load_or_build native in
      let* memory_env = Mem_environment.load_or_build memory in
      Lwt_list.iter_s
        (fun text ->
          let native_cq = lower native_env text and memory_cq = lower memory_env text in
          let* n = Query_engine.execute native native_cq.query in
          let* m = Mem_engine.execute memory memory_cq.query in
          let apply cq = function Ok r -> render_rows (Core_query.apply cq r) | Error e -> [ e ] in
          (* Row order is only defined when the query has an order by. *)
          let norm rows = if native_cq.order_by <> [] then rows else List.sort String.compare rows in
          Alcotest.(check (list string)) text (norm (apply native_cq n)) (norm (apply memory_cq m));
          Lwt.return_unit)
        dsl_queries)

let test_pagination_parity () =
  with_native "pagination" (fun _ native ->
      let q = parse "created_by(W, A), person(A)" in
      Lwt_list.iter_s
        (fun (offset, limit) ->
          let* n = Query_engine.execute_streaming native q ~offset ~limit in
          let* m = Mem_engine.execute_streaming memory q ~offset ~limit in
          let count = function Ok (r : Query_engine.result) -> List.length r.bindings | Error _ -> -1 in
          Alcotest.(check int) (Printf.sprintf "offset %d limit %d" offset limit) (count n) (count m);
          Lwt.return_unit)
        [ (0, 1); (1, 1); (0, 2); (2, 5); (3, 5); (0, 100) ])

let test_introspection_parity () =
  with_native "introspection" (fun _ native ->
      let* n_names = Pack_backend.list_predicates native in
      let* m_names = Memory_store.list_predicates memory in
      let sorted = List.sort String.compare in
      Alcotest.(check (list string)) "predicates" (sorted n_names) (sorted m_names);
      let* () =
        Lwt_list.iter_s
          (fun p ->
            let* n = Pack_backend.get_manifest native p in
            let* m = Memory_store.get_manifest memory p in
            let json = Option.map (fun m -> Yojson.Safe.to_string (Manifest.to_json m)) in
            Alcotest.(check (option string)) ("manifest " ^ p) (json n) (json m);
            Lwt.return_unit)
          n_names
      in
      let* n_env = Query_environment.load_or_build native in
      let* m_env = Mem_environment.load_or_build memory in
      Alcotest.(check string) "environment fingerprint" n_env.fingerprint m_env.fingerprint;
      Lwt.return_unit)

let test_reopen_readonly () =
  with_native "reopen" (fun dir native ->
      let* before = Query_engine.execute native (parse "created_by(W, A), exhibited_at(W, E)") in
      let* () = Pack_backend.close_repo (Pack_backend.Store.repo native) in
      let* reopened = Pack_backend.init ~readonly:true dir in
      let* after = Query_engine.execute reopened (parse "created_by(W, A), exhibited_at(W, E)") in
      Alcotest.(check (list string)) "same results after reopening read-only" (render_result before) (render_result after);
      let* m = Mem_engine.execute memory (parse "created_by(W, A), exhibited_at(W, E)") in
      Alcotest.(check (list string)) "matches in-memory store" (render_result m) (render_result after);
      Pack_backend.close_repo (Pack_backend.Store.repo reopened))

let () =
  Alcotest.run "BeingDB Runtime parity (native pack vs in-memory)"
    [
      ( "Parity",
        [
          Alcotest.test_case "core queries" `Quick test_core_parity;
          Alcotest.test_case "dsl queries" `Quick test_dsl_parity;
          Alcotest.test_case "pagination" `Quick test_pagination_parity;
          Alcotest.test_case "introspection" `Quick test_introspection_parity;
          Alcotest.test_case "reopen compiled pack read-only" `Quick test_reopen_readonly;
        ] );
    ]
