(** Query_diagnostics over the in-memory store: each diagnostic, the two
    proven repairs, JSON stability, and that diagnostics never disturb
    valid queries or query execution. Portable runtime only. *)

open Beingdb_runtime
module Env = Query_environment.Make (Memory_store)
module Engine = Query_engine.Make (Memory_store)
module Report = Query_diagnostics.Report (Memory_store)
module U = Yojson.Safe.Util

let rec run p =
  match Lwt.state p with
  | Lwt.Return v -> v
  | Lwt.Fail e -> raise e
  | Lwt.Sleep ->
      Lwt.wakeup_paused ();
      run p

let atom s = Value.Atom s

let declare roles description =
  Result.get_ok
    (Predicate_declaration.make
       ~arguments:(Some (List.map (fun role -> { Predicate_declaration.role; semantic_type = None }) roles))
       ~description:(Some description))

let store =
  lazy
    (let s = Memory_store.create () in
     let add ?declaration name rows = Memory_store.add_predicate ?declaration s name (List.map (Fact.make name) rows) in
     add ~declaration:(declare [ "Work"; "Artist" ] "Relates a work to its artist.") "created_by"
       [ [ atom "work_1"; atom "artist_1" ]; [ atom "work_2"; atom "artist_2" ]; [ atom "work_3"; atom "artist_1" ] ];
     add ~declaration:(declare [ "Work"; "Year" ] "Year a work was made.") "year_created"
       [ [ atom "work_1"; Value.Year 1979 ]; [ atom "work_2"; Value.Year 1985 ] ];
     add ~declaration:(declare [ "Work"; "Place" ] "Where a work was made.") "made_at" [ [ atom "work_1"; atom "oval_house" ] ];
     add ~declaration:(declare [ "Person"; "Employer" ] "Who employed a person.") "employed_by" [ [ atom "artist_1"; atom "bbc" ] ];
     add "person" [ [ atom "artist_1" ]; [ atom "artist_2" ] ];
     add "held_at"
       [ [ atom "work_1"; atom "tate_modern" ]; [ atom "work_2"; atom "tate_britain" ]; [ atom "work_3"; atom "whitechapel_gallery" ] ];
     add "titled" [ [ atom "work_1"; Value.String "Hey Bud" ]; [ atom "work_2"; Value.String "Shadow of a Journey" ] ];
     s)

let env = lazy (run (Env.build (Lazy.force store)))
let report text = `Assoc (run (Report.fields (Lazy.force store) (Lazy.force env) text))
let diagnostics r = U.(r |> member "diagnostics" |> to_list)
let codes r = List.map (fun d -> U.(d |> member "code" |> to_string)) (diagnostics r)
let find_code r c = List.find (fun d -> U.(d |> member "code" |> to_string) = c) (diagnostics r)
let repaired r = U.(r |> member "repair" |> member "query" |> to_string)
let has_repair r = U.member "repair" r <> `Null

let rows text =
  match Dsl_parser.parse text with
  | Error e -> Alcotest.fail e
  | Ok surface -> (
      match Dsl_lower.lower (Lazy.force env) surface with
      | { core_query = Some cq; _ } -> (
          match run (Engine.execute (Lazy.force store) cq.Core_query.query) with
          | Ok result ->
              let vars, rows = Core_query.apply cq result in
              ignore vars;
              List.map (fun row -> String.concat "," (List.map (function Some v -> Value.canonical_string v | None -> "-") row)) rows
              |> List.sort compare
          | Error e -> Alcotest.fail e)
      | _ -> Alcotest.fail "invalid query")

let test_clean_query () =
  let q = "find Work, Artist\nwhere\n  created_by(Work, Artist)\n  year_created(Work, Y)\n  Y > @1980\n" in
  let r = report q in
  Alcotest.(check bool) "valid" true U.(r |> member "valid" |> to_bool);
  Alcotest.(check (list string)) "no diagnostics" [] (codes r);
  Alcotest.(check bool) "no repair" false (has_repair r);
  Alcotest.(check bool) "not provably empty" false U.(r |> member "provablyEmpty" |> to_bool);
  Alcotest.(check (list string)) "execution unchanged" [ "work_2,artist_2" ] (rows q)

let test_swap_repair () =
  let q = "find Work\nwhere\n  created_by(artist_1, Work)\n" in
  let r = report q in
  let d = find_code r "constant_not_at_position" in
  Alcotest.(check string) "severity" "error" U.(d |> member "severity" |> to_string);
  Alcotest.(check (list int)) "occurs at" [ 1 ] U.(d |> member "evidence" |> member "occursAtPositions" |> to_list |> List.map to_int);
  Alcotest.(check string) "declared role" "Work" U.(d |> member "evidence" |> member "declaredRole" |> to_string);
  Alcotest.(check string) "repair kind" "swap_arguments" U.(d |> member "repair" |> member "kind" |> to_string);
  Alcotest.(check bool) "role warning too" true (List.mem "role_name_mismatch" (codes r));
  Alcotest.(check bool) "provably empty" true U.(r |> member "provablyEmpty" |> to_bool);
  Alcotest.(check (list string)) "original returns nothing" [] (rows q);
  Alcotest.(check string) "repaired text" "find Work\nwhere\n  created_by(Work, artist_1)\n" (repaired r);
  Alcotest.(check (list string)) "repaired rows" [ "work_1"; "work_3" ] (rows (repaired r));
  let r2 = report (repaired r) in
  Alcotest.(check (list string)) "repaired query is clean" [] (codes r2)

let test_swap_literals_round_trip () =
  (* An invalid query (year where an atom is expected) is still repaired,
     and the year literal is re-rendered in DSL syntax. *)
  let r = report "find Work\nwhere\n    year_created(@1979, Work)\n" in
  Alcotest.(check bool) "invalid" false U.(r |> member "valid" |> to_bool);
  Alcotest.(check string) "repaired" "find Work\nwhere\n    year_created(Work, @1979)\n" (repaired r);
  Alcotest.(check bool) "repaired is valid" true U.(report (repaired r) |> member "valid" |> to_bool)

let test_no_unproven_repairs () =
  (* artist_2 cannot move to position 0, so no swap is proven. *)
  let r = report "find X\nwhere\n  created_by(artist_1, artist_2)\n  person(X)\n" in
  Alcotest.(check bool) "no repair" false (has_repair r);
  (* An atom that occurs nowhere. *)
  let r = report "find Work\nwhere\n  created_by(Work, nobody)\n" in
  Alcotest.(check (list string)) "unknown constant" [ "unknown_constant" ] (codes r);
  Alcotest.(check bool) "no repair" false (has_repair r);
  (* In optional scope the clause alone is empty: warning, no repair. *)
  let r = report "find Work, A\nwhere\n  year_created(Work, Y)\n  optional\n    created_by(artist_1, A)\n" in
  let d = find_code r "constant_not_at_position" in
  Alcotest.(check string) "warning" "warning" U.(d |> member "severity" |> to_string);
  Alcotest.(check string) "scope" "optional" U.(d |> member "scope" |> to_string);
  Alcotest.(check bool) "no repair" false (has_repair r);
  Alcotest.(check bool) "not provably empty" false U.(r |> member "provablyEmpty" |> to_bool)

let test_singleton_variable () =
  let q = "find Person\nwhere\n  employed_by(Person, BBC)\n" in
  let r = report q in
  let d = find_code r "singleton_variable" in
  Alcotest.(check string) "variable" "BBC" U.(d |> member "variable" |> to_string);
  Alcotest.(check string) "repair kind" "replace_variable" U.(d |> member "repair" |> member "kind" |> to_string);
  Alcotest.(check string) "repaired" "find Person\nwhere\n  employed_by(Person, bbc)\n" (repaired r);
  Alcotest.(check (list string)) "repaired rows" [ "artist_1" ] (rows (repaired r));
  let r = report "find Work\nwhere\n  made_at(Work, OvalHouse)\n" in
  Alcotest.(check string) "camel case" "find Work\nwhere\n  made_at(Work, oval_house)\n" (repaired r);
  (* A singleton whose name is not an atom there: warning only. *)
  let r = report "find Work\nwhere\n  created_by(Work, Artist)\n" in
  Alcotest.(check (list string)) "warning only" [ "singleton_variable" ] (codes r);
  Alcotest.(check bool) "no repair" false (has_repair r);
  Alcotest.(check bool) "not provably empty" false U.(r |> member "provablyEmpty" |> to_bool);
  (* Projected, ordered or joined variables are not singletons. *)
  let r = report "find Work\nwhere\n  created_by(Work, A)\n  person(A)\n" in
  Alcotest.(check (list string)) "joined" [] (codes r)

let test_role_name_mismatch () =
  let r = report "find Artist, Work\nwhere\n  created_by(Artist, Work)\n" in
  let ds = List.filter (fun d -> U.(d |> member "code" |> to_string) = "role_name_mismatch") (diagnostics r) in
  Alcotest.(check int) "both arguments" 2 (List.length ds);
  Alcotest.(check bool) "no repair from names alone" false (has_repair r)

let suggestions d =
  match U.member "evidence" d with
  | `Null -> []
  | e -> ( match U.member "suggestions" e with `Null -> [] | l -> U.(l |> to_list |> List.map to_string))

let test_constant_suggestions () =
  (* A misspelled atom: ranked suggestions from that position, as a hint only. *)
  let r = report "find Work\nwhere\n  held_at(Work, tate_modren)\n" in
  let d = find_code r "unknown_constant" in
  Alcotest.(check (list string)) "typo" [ "tate_modern" ] (suggestions d);
  Alcotest.(check bool) "did you mean" true
    (let m = U.(d |> member "message" |> to_string) in
     let s = "Did you mean tate_modern?" in
     String.length m >= String.length s && String.sub m (String.length m - String.length s) (String.length s) = s);
  Alcotest.(check bool) "not a repair" false (has_repair r);
  (* A shared word: closest first. *)
  let r = report "find Work\nwhere\n  held_at(Work, tate)\n" in
  Alcotest.(check (list string)) "partial" [ "tate_modern"; "tate_britain" ] (suggestions (find_code r "unknown_constant"));
  (* Strings, case- and space-insensitively, rendered as DSL literals. *)
  let r = report "find Work\nwhere\n  titled(Work, \"hey  bud\")\n" in
  Alcotest.(check (list string)) "string" [ "\"Hey Bud\"" ] (suggestions (find_code r "constant_not_at_position"));
  (* Nothing similar: no suggestions field at all. *)
  let r = report "find Work\nwhere\n  held_at(Work, nowhere)\n" in
  Alcotest.(check (list string)) "none" [] (suggestions (find_code r "unknown_constant"));
  (* Present elsewhere in the predicate: the position is wrong, not the spelling. *)
  let r = report "find Work\nwhere\n  created_by(artist_1, Work)\n" in
  Alcotest.(check (list string)) "wrong position" [] (suggestions (find_code r "constant_not_at_position"));
  (* Numeric tokens alone are not similarity. *)
  Alcotest.(check (list string)) "numeric token" [] (Predicate_suggest.suggest_value ~known:[ "work_1"; "work_2" ] "artist_1");
  (* Nor is one common word between otherwise unrelated values. *)
  Alcotest.(check (list string)) "one common word" []
    (Predicate_suggest.suggest_value ~known:[ "The Video Stairs" ] "Scratch Video Volume 1");
  Alcotest.(check (list string)) "most words shared" [ "The Video Stairs" ]
    (Predicate_suggest.suggest_value ~known:[ "The Video Stairs" ] "Video Stairs");
  Alcotest.(check (list string)) "close spelling, one shared word" [ "david_critchley" ]
    (Predicate_suggest.suggest_value ~known:[ "david_critchley"; "david_hall" ] "david_critchly")

let test_unsatisfiable_comparison () =
  let q = "find Work\nwhere\n  year_created(Work, Y)\n  Y > @2090\n" in
  let r = report q in
  let d = find_code r "unsatisfiable_comparison" in
  Alcotest.(check string) "severity" "error" U.(d |> member "severity" |> to_string);
  Alcotest.(check string) "variable" "Y" U.(d |> member "variable" |> to_string);
  Alcotest.(check int) "position" 1 U.(d |> member "argumentPosition" |> to_int);
  Alcotest.(check string) "message"
    "No year_created fact has a value at argument 1 satisfying Y > @2090, so the query returns no rows. Values there range from @1979 to @1985."
    U.(d |> member "message" |> to_string);
  Alcotest.(check string) "min" "1979" U.(d |> member "evidence" |> member "observedRange" |> member "min" |> member "value" |> to_string);
  Alcotest.(check bool) "provably empty" true U.(r |> member "provablyEmpty" |> to_bool);
  Alcotest.(check (list string)) "and it is" [] (rows q);
  (* Literal on the left, and between, through a join. *)
  let r = report "find Work\nwhere\n  created_by(Work, A)\n  year_created(Work, Y)\n  @2090 < Y\n" in
  Alcotest.(check string) "flipped" "year_created" U.(find_code r "unsatisfiable_comparison" |> member "predicate" |> to_string);
  let r = report "find Work\nwhere\n  year_created(Work, Y)\n  Y between @1990 and @2000\n" in
  Alcotest.(check bool) "between" true (List.mem "unsatisfiable_comparison" (codes r));
  (* Satisfiable comparisons, including a value in the gap between facts. *)
  List.iter
    (fun c ->
      let r = report ("find Work\nwhere\n  year_created(Work, Y)\n  " ^ c ^ "\n") in
      Alcotest.(check bool) c false (List.mem "unsatisfiable_comparison" (codes r)))
    [ "Y > @1980"; "Y >= @1985"; "Y = @1979"; "Y between @1979 and @1979"; "Y != @1979" ];
  Alcotest.(check bool) "gap" true
    (List.mem "unsatisfiable_comparison" (codes (report "find Work\nwhere\n  year_created(Work, Y)\n  Y between @1980 and @1984\n")));
  (* Only top-level comparisons on positively bound variables are judged. *)
  let r = report "find Work, Y\nwhere\n  created_by(Work, A)\n  optional\n    year_created(Work, Y)\n  Y > @2090\n" in
  Alcotest.(check bool) "optional binding" false (List.mem "unsatisfiable_comparison" (codes r))

let test_disjoint_join () =
  let q = "find Work\nwhere\n  created_by(Work, A)\n  employed_by(Work, E)\n" in
  let r = report q in
  let d = find_code r "disjoint_join" in
  Alcotest.(check string) "variable" "Work" U.(d |> member "variable" |> to_string);
  Alcotest.(check int) "two sites" 2 U.(d |> member "evidence" |> member "sites" |> to_list |> List.length);
  Alcotest.(check bool) "provably empty" true U.(r |> member "provablyEmpty" |> to_bool);
  Alcotest.(check (list string)) "and it is" [] (rows q)

let test_contradictory_negation () =
  let q = "find Work\nwhere\n  made_at(Work, oval_house)\n  not\n    made_at(Work, oval_house)\n" in
  let r = report q in
  Alcotest.(check bool) "contradiction" true (List.mem "contradictory_negation" (codes r));
  Alcotest.(check (list string)) "empty" [] (rows q)

let test_validation_unchanged () =
  let r = report "find W\nwhere\n  created_by(W)\n" in
  Alcotest.(check bool) "invalid" false U.(r |> member "valid" |> to_bool);
  Alcotest.(check string) "arity" "arity_mismatch" U.(r |> member "errors" |> index 0 |> member "code" |> to_string);
  let r = report "find W, Z\nwhere\n  created_by(W, A)\n" in
  Alcotest.(check string) "unbound" "unbound_projection" U.(r |> member "errors" |> index 0 |> member "code" |> to_string);
  let r = report "find W\nwhere\n  created_bi(W, A)\n" in
  Alcotest.(check string) "unknown" "unknown_predicate" U.(r |> member "errors" |> index 0 |> member "code" |> to_string);
  let r = report "find W where x" in
  Alcotest.(check string) "syntax" "syntax_error" U.(r |> member "errors" |> index 0 |> member "code" |> to_string);
  Alcotest.(check (list string)) "no diagnostics" [] (codes r)

(* The exact JSON shape is an API: clients (WASM, MCP, WebLLM) parse it. *)
let test_json_stability () =
  let r = report "find Work\nwhere\n  created_by(artist_1, Work)\n" in
  Alcotest.(check string) "json"
    {|{"valid":true,"errors":[],"warnings":[],"diagnostics":[{"code":"constant_not_at_position","severity":"error","message":"No created_by fact has 'artist_1' as argument 0. 'artist_1' occurs in created_by only at argument 1.","line":3,"predicate":"created_by","argumentPosition":0,"value":{"type":"atom","value":"artist_1"},"scope":"positive","evidence":{"declaredRole":"Work","occursAtPositions":[1],"occursIn":[{"predicate":"employed_by","argumentPosition":0},{"predicate":"person","argumentPosition":0}],"occursInCount":2},"repair":{"kind":"swap_arguments","predicate":"created_by","line":3,"positions":[0,1]}},{"code":"role_name_mismatch","severity":"warning","message":"Work is argument 1 of created_by, whose declared role is Artist; Work is the role of argument 0.","line":3,"predicate":"created_by","argumentPosition":1,"variable":"Work","scope":"positive","evidence":{"declaredRole":"Artist","matchesRoleAt":0,"matchesRole":"Work"}}],"provablyEmpty":true,"repair":{"query":"find Work\nwhere\n  created_by(Work, artist_1)\n","applied":[{"kind":"swap_arguments","predicate":"created_by","line":3,"positions":[0,1]}]}}|}
    (Yojson.Safe.to_string r)

let () =
  Alcotest.run "Query diagnostics"
    [
      ( "diagnostics",
        [
          Alcotest.test_case "clean query unchanged" `Quick test_clean_query;
          Alcotest.test_case "argument swap repair" `Quick test_swap_repair;
          Alcotest.test_case "swap re-renders literals" `Quick test_swap_literals_round_trip;
          Alcotest.test_case "no unproven repairs" `Quick test_no_unproven_repairs;
          Alcotest.test_case "singleton variable" `Quick test_singleton_variable;
          Alcotest.test_case "role name mismatch" `Quick test_role_name_mismatch;
          Alcotest.test_case "constant suggestions" `Quick test_constant_suggestions;
          Alcotest.test_case "unsatisfiable comparison" `Quick test_unsatisfiable_comparison;
          Alcotest.test_case "disjoint join" `Quick test_disjoint_join;
          Alcotest.test_case "contradictory negation" `Quick test_contradictory_negation;
          Alcotest.test_case "validation unchanged" `Quick test_validation_unchanged;
          Alcotest.test_case "JSON stability" `Quick test_json_stability;
        ] );
    ]
