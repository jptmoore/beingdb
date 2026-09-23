(** Storage-independent runtime tests: the portable query runtime
    (parser, planner, evaluator, environment, DSL) executed against the
    in-memory {!Beingdb_runtime.Memory_store}.

    Deliberately links only [beingdb_runtime] and core [lwt] -- no Unix,
    Irmin, Git or Dream -- and drives Lwt without [Lwt_main], proving the
    runtime needs no Unix scheduler. *)

open Beingdb_runtime
module Engine = Query_engine.Make (Memory_store)
module Environment = Query_environment.Make (Memory_store)

(* Drive a promise to completion without Lwt_unix: the engine only ever
   blocks on [Lwt.pause], and Memory_store resolves immediately. *)
let rec run p =
  match Lwt.state p with
  | Lwt.Return v -> v
  | Lwt.Fail e -> raise e
  | Lwt.Sleep ->
      if Lwt.paused_count () = 0 then failwith "promise blocked on something other than Lwt.pause";
      Lwt.wakeup_paused ();
      run p

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
  ]

let store = Memory_store.of_facts facts

let first_args (fs : Fact.t list) =
  List.sort String.compare (List.map (fun (f : Fact.t) -> Value.canonical_string (List.hd f.arguments)) fs)

let binding_strings (r : Query_engine.result) =
  let render b = List.sort compare (List.map (fun (v, x) -> v ^ "=" ^ Value.canonical_string x) b) in
  List.sort String.compare (List.map (fun b -> String.concat ";" (render b)) r.bindings)

let core text =
  match Query_parser.parse_query_result text with
  | Error e -> Alcotest.failf "parse error: %s" e
  | Ok q -> ( match run (Engine.execute store q) with Ok r -> r | Error e -> Alcotest.failf "execution error: %s" e)

let dsl text =
  let env = run (Environment.build store) in
  match Dsl_parser.parse text with
  | Error e -> Alcotest.failf "parse error: %s" e
  | Ok surface -> (
      match Dsl_lower.lower env surface with
      | { errors = _ :: _ as errors; _ } -> Alcotest.failf "invalid: %s" (String.concat "; " (List.map Validation_error.message errors))
      | { core_query = None; _ } -> Alcotest.fail "no core query"
      | { core_query = Some cq; _ } -> (
          match run (Engine.execute store cq.query) with
          | Error e -> Alcotest.failf "execution error: %s" e
          | Ok r -> Core_query.apply cq r))

(* --- equality lookups --- *)

let test_equality_lookup () =
  let by_artist = run (Memory_store.equality_lookup store "created_by" 1 (Value.Atom "alice")) in
  Alcotest.(check (list string)) "alice's works" [ "work1"; "work2" ] (first_args by_artist);
  let by_int = run (Memory_store.equality_lookup store "value" 1 (Value.Integer 1979L)) in
  let by_year = run (Memory_store.equality_lookup store "value" 1 (Value.Year 1979)) in
  Alcotest.(check (list string)) "integer matches" [ "x" ] (first_args by_int);
  Alcotest.(check int) "year never equals integer" 0 (List.length by_year)

(* --- range lookups --- *)

let range predicate position ~lower ~upper =
  run (Memory_store.range_lookup store predicate position ~lower ~upper)

let test_range_lookup () =
  (match range "born" 1 ~lower:(Some (Value.Year 1945, true)) ~upper:None with
  | Ok fs -> Alcotest.(check (list string)) "born >= 1945" [ "alice"; "carol" ] (first_args fs)
  | Error e -> Alcotest.fail e);
  (match range "score" 1 ~lower:(Some (Value.Decimal (Decimal.make 9L 1), true)) ~upper:None with
  | Ok fs -> Alcotest.(check (list string)) "integer/decimal promotion" [ "work1"; "work2" ] (first_args fs)
  | Error e -> Alcotest.fail e);
  (match range "value" 1 ~lower:(Some (Value.Integer 1900L, false)) ~upper:None with
  | Ok fs -> Alcotest.(check (list string)) "non-ordered string excluded" [ "x" ] (first_args fs)
  | Error e -> Alcotest.fail e);
  (match range "opened" 1 ~lower:(Some (Value.Integer 1979L, true)) ~upper:None with
  | Ok _ -> Alcotest.fail "expected date/integer mismatch error"
  | Error _ -> ());
  match range "born" 1 ~lower:None ~upper:None with
  | Ok fs -> Alcotest.(check int) "no bounds" 0 (List.length fs)
  | Error e -> Alcotest.fail e

let test_range_query () =
  let r = core "born(P, Y), Y between 1940 and 1960" in
  Alcotest.(check (list string)) "between" [ "P=alice;Y=1951"; "P=bob;Y=1941" ] (binding_strings r);
  let r = core "opened(E, D), D >= @2020-01-01" in
  Alcotest.(check (list string)) "date comparison" [ "D=2020-01-01;E=ex2" ] (binding_strings r)

(* --- joins and bindings --- *)

let test_join () =
  let r = core "created_by(W, A), exhibited_at(W, E)" in
  Alcotest.(check (list string)) "variables" [ "A"; "E"; "W" ] (List.sort String.compare r.variables);
  Alcotest.(check (list string)) "joined" [ "A=alice;E=ex1;W=work1"; "A=bob;E=ex2;W=work3" ] (binding_strings r)

let test_bindings () =
  let r = core "created_by(W, alice)" in
  Alcotest.(check (list string)) "constant not bound" [ "W" ] r.variables;
  Alcotest.(check (list string)) "bound works" [ "W=work1"; "W=work2" ] (binding_strings r);
  let r = core "created_by(W, A), person(A), born(A, @1941)" in
  Alcotest.(check (list string)) "typed literal in join" [ "A=bob;W=work3" ] (binding_strings r)

(* --- pagination --- *)

let test_pagination () =
  let q = match Query_parser.parse_query_result "created_by(W, A), person(A)" with Ok q -> q | Error e -> failwith e in
  let page offset limit =
    match run (Engine.execute_streaming store q ~offset ~limit) with Ok r -> binding_strings r | Error e -> Alcotest.fail e
  in
  let all = binding_strings (core "created_by(W, A), person(A)") in
  let pages = page 0 1 @ page 1 1 @ page 2 1 in
  Alcotest.(check int) "total" 3 (List.length all);
  Alcotest.(check (list string)) "pages cover all rows once" all (List.sort String.compare pages);
  Alcotest.(check int) "limit respected" 2 (List.length (page 0 2));
  Alcotest.(check int) "offset past end" 0 (List.length (page 3 5))

(* --- predicate introspection --- *)

let test_introspection () =
  let names = List.sort String.compare (run (Memory_store.list_predicates store)) in
  Alcotest.(check (list string)) "predicates"
    [ "born"; "created_by"; "exhibited_at"; "opened"; "person"; "score"; "value" ] names;
  (match run (Memory_store.get_manifest store "score") with
  | None -> Alcotest.fail "missing manifest"
  | Some m ->
      Alcotest.(check int) "arity" 2 m.Manifest.arity;
      Alcotest.(check int) "fact count" 3 m.Manifest.fact_count);
  let env = run (Environment.build store) in
  Alcotest.(check bool) "sha256 fingerprint" true (String.starts_with ~prefix:"sha256:" env.Query_environment.fingerprint);
  match Query_environment.find env "born" with
  | None -> Alcotest.fail "born missing from environment"
  | Some p ->
      Alcotest.(check int) "born arity" 2 p.arity;
      Alcotest.(check (list string)) "born arg types" [ "year" ]
        (List.nth p.arguments 1).Query_environment.types

(* --- expressive language end to end --- *)

let row_strings rows =
  List.map (fun row -> String.concat "," (List.map (function Some v -> Value.canonical_string v | None -> "-") row)) rows

let test_dsl () =
  let vars, rows =
    dsl "find Artist, Work\nwhere\n  person(Artist)\n  created_by(Work, Artist)\norder by Work descending\nlimit 2\n"
  in
  Alcotest.(check (list string)) "projection" [ "Artist"; "Work" ] vars;
  Alcotest.(check (list string)) "ordered and limited" [ "bob,work3"; "alice,work2" ] (row_strings rows);
  let _, rows = dsl "find P, W\nwhere\n  person(P)\n  optional\n    created_by(W, P)\norder by P ascending\n" in
  Alcotest.(check (list string)) "optional left join" [ "alice,work1"; "alice,work2"; "bob,work3"; "carol,-" ]
    (List.sort String.compare (row_strings rows))

let () =
  Alcotest.run "BeingDB Runtime (in-memory store)"
    [
      ("Lookups", [ Alcotest.test_case "equality" `Quick test_equality_lookup; Alcotest.test_case "range" `Quick test_range_lookup ]);
      ( "Queries",
        [
          Alcotest.test_case "range query" `Quick test_range_query;
          Alcotest.test_case "join" `Quick test_join;
          Alcotest.test_case "bindings" `Quick test_bindings;
          Alcotest.test_case "pagination" `Quick test_pagination;
          Alcotest.test_case "dsl" `Quick test_dsl;
        ] );
      ("Introspection", [ Alcotest.test_case "predicates and environment" `Quick test_introspection ]);
    ]
