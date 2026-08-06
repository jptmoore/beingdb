(** Storage and indexing tests for the typed Pack backend: fact storage,
    positional indexes (equality and range lookups), mixed-type branches,
    and full typed fact reconstruction. *)

open Lwt.Syntax
open Beingdb

let create_test_pack name =
  let test_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "beingdb_storage_test_%s_%d_%d" name (Unix.getpid ()) (Random.bits ()))
  in
  (try Unix.rmdir test_dir with _ -> ());
  Unix.mkdir test_dir 0o755;
  test_dir

let cleanup test_dir =
  let _ = Unix.system (Printf.sprintf "rm -rf %s" (Filename.quote test_dir)) in
  ()

let with_store name facts f =
  let test_dir = create_test_pack name in
  Lwt_main.run
    (let* store = Pack_backend.init ~fresh:true test_dir in
     let by_predicate = Hashtbl.create 8 in
     List.iter
       (fun (fact : Fact.t) ->
         let existing = try Hashtbl.find by_predicate fact.predicate with Not_found -> [] in
         Hashtbl.replace by_predicate fact.predicate (fact :: existing))
       facts;
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

let fact predicate args = Fact.make predicate args

let has_fact fact_id_list (f : Fact.t) = List.exists (fun (f' : Fact.t) -> Fact.fact_id f' = Fact.fact_id f) fact_id_list

let range_ok store predicate position ~lower ~upper =
  let* r = Pack_backend.range_lookup store predicate position ~lower ~upper in
  match r with Ok fs -> Lwt.return fs | Error e -> Alcotest.fail e

(* --- equality lookups --- *)

let test_equality_lookup_every_position () =
  let f1 = fact "created" [ Value.Atom "alice"; Value.Atom "bob" ] in
  let f2 = fact "created" [ Value.Atom "carol"; Value.Atom "dave" ] in
  with_store "equality_positions" [ f1; f2 ] (fun store ->
      let* by_pos0 = Pack_backend.equality_lookup store "created" 0 (Value.Atom "alice") in
      let* by_pos1 = Pack_backend.equality_lookup store "created" 1 (Value.Atom "dave") in
      Alcotest.(check int) "position 0 lookup" 1 (List.length by_pos0);
      Alcotest.(check bool) "position 0 finds f1" true (has_fact by_pos0 f1);
      Alcotest.(check int) "position 1 lookup" 1 (List.length by_pos1);
      Alcotest.(check bool) "position 1 finds f2" true (has_fact by_pos1 f2);
      Lwt.return_unit)

let test_equality_lookup_typed () =
  let f1 = fact "confidence" [ Value.Atom "a1"; Value.Decimal (Decimal.make 92L 2) ] in
  let f2 = fact "confidence" [ Value.Atom "a2"; Value.Decimal (Decimal.make 90L 2) ] in
  with_store "equality_typed" [ f1; f2 ] (fun store ->
      let* results = Pack_backend.equality_lookup store "confidence" 1 (Value.Decimal (Decimal.make 900L 3)) in
      (* 0.900 canonicalizes to the same decimal as 0.90 *)
      Alcotest.(check int) "matches by canonical decimal" 1 (List.length results);
      Alcotest.(check bool) "finds f2" true (has_fact results f2);
      Lwt.return_unit)

(* --- range scans --- *)

let test_integer_range_scan () =
  let facts =
    [ ("item1", 10L); ("item2", 20L); ("item3", 30L) ]
    |> List.map (fun (id, n) -> fact "value" [ Value.Atom id; Value.Integer n ])
  in
  with_store "integer_range" facts (fun store ->
      let* results = range_ok store "value" 1 ~lower:(Some (Value.Integer 15L, true)) ~upper:None in
      Alcotest.(check int) "two results >= 15" 2 (List.length results);
      Lwt.return_unit)

let test_integer_negative_to_positive_ordering () =
  let facts =
    [ ("a", -5L); ("b", 0L); ("c", 5L) ] |> List.map (fun (id, n) -> fact "value" [ Value.Atom id; Value.Integer n ])
  in
  with_store "integer_neg_pos" facts (fun store ->
      let* results =
        range_ok store "value" 1 ~lower:(Some (Value.Integer (-3L), true)) ~upper:(Some (Value.Integer 3L, true))
      in
      Alcotest.(check int) "only 'b' (0) is in [-3,3]" 1 (List.length results);
      (match results with
      | [ f ] -> Alcotest.(check string) "correct fact" "value" f.Fact.predicate
      | _ -> Alcotest.fail "expected exactly one result");
      let* all_geq = range_ok store "value" 1 ~lower:(Some (Value.Integer 0L, true)) ~upper:None in
      Alcotest.(check int) ">= 0 includes b and c" 2 (List.length all_geq);
      Lwt.return_unit)

let test_year_range_scan () =
  let facts = [ 1899; 1900; 1949; 1950 ] |> List.map (fun y -> fact "birth_year" [ Value.Atom (string_of_int y); Value.Year y ]) in
  with_store "year_range" facts (fun store ->
      let* results =
        range_ok store "birth_year" 1 ~lower:(Some (Value.Year 1900, true)) ~upper:(Some (Value.Year 1950, false))
      in
      Alcotest.(check int) "1900 and 1949 only" 2 (List.length results);
      Lwt.return_unit)

let mkdate y m d = match Value.make_date ~year:y ~month:m ~day:d with Ok v -> v | Error e -> failwith e

let test_date_range_scan () =
  let facts =
    [ (2018, 12, 31); (2019, 1, 1); (2019, 6, 15); (2019, 12, 31); (2020, 1, 1) ]
    |> List.map (fun (y, m, d) -> fact "opened" [ Value.Atom "x"; mkdate y m d ])
  in
  with_store "date_range" facts (fun store ->
      let* results =
        range_ok store "opened" 1 ~lower:(Some (mkdate 2019 1 1, true)) ~upper:(Some (mkdate 2019 12 31, true))
      in
      Alcotest.(check int) "three dates in 2019" 3 (List.length results);
      Lwt.return_unit)

let mkinstant s = match Calendar.parse_instant s with Ok t -> Value.Instant t | Error e -> failwith e

let test_instant_range_scan () =
  let facts =
    [
      "2018-12-31T23:59:59Z"; "2019-01-01T00:00:00Z"; "2019-06-15T12:00:00Z"; "2019-12-31T23:59:59Z";
      "2020-01-01T00:00:00Z";
    ]
    |> List.map (fun s -> fact "captured_at" [ Value.Atom "x"; mkinstant s ])
  in
  with_store "instant_range" facts (fun store ->
      let* results =
        range_ok store "captured_at" 1
          ~lower:(Some (mkinstant "2019-01-01T00:00:00Z", true))
          ~upper:(Some (mkinstant "2020-01-01T00:00:00Z", false))
      in
      Alcotest.(check int) "three instants in 2019" 3 (List.length results);
      Lwt.return_unit)

(* --- mixed-type branches --- *)

let test_mixed_type_index_branches () =
  let f1 = fact "value" [ Value.Atom "item_1"; Value.Integer 1979L ] in
  let f2 = fact "value" [ Value.Atom "item_2"; Value.String "unknown" ] in
  with_store "mixed_types" [ f1; f2 ] (fun store ->
      let* all = Pack_backend.query_all store "value" in
      Alcotest.(check int) "both facts present" 2 (List.length all);
      let* by_int = Pack_backend.equality_lookup store "value" 1 (Value.Integer 1979L) in
      let* by_str = Pack_backend.equality_lookup store "value" 1 (Value.String "unknown") in
      Alcotest.(check bool) "integer branch isolated" true (has_fact by_int f1 && List.length by_int = 1);
      Alcotest.(check bool) "string branch isolated" true (has_fact by_str f2 && List.length by_str = 1);
      let* manifest = Pack_backend.get_manifest store "value" in
      (match manifest with
      | None -> Alcotest.fail "expected a manifest"
      | Some m ->
          let position1 = List.nth m.Manifest.positions 1 in
          let type_names = List.map fst position1.Manifest.type_stats |> List.sort String.compare in
          Alcotest.(check (list string)) "two type branches" [ "integer"; "string" ] type_names);
      Lwt.return_unit)

(* --- full typed fact reconstruction --- *)

let test_full_typed_fact_reconstruction () =
  let instant = mkinstant "2026-08-06T12:15:00Z" in
  let f =
    fact "everything"
      [
        Value.Atom "a";
        Value.String "s";
        Value.Lang_string { value = "hello"; language = "en" };
        Value.Integer (-7L);
        Value.Decimal (Decimal.make 314L 2);
        Value.Boolean true;
        Value.Year 1979;
        (match Value.make_year_month ~year:1979 ~month:6 with Ok v -> v | Error e -> failwith e);
        mkdate 1979 6 15;
        instant;
        Value.Uri "https://example.org/";
      ]
  in
  with_store "full_reconstruction" [ f ] (fun store ->
      let* all = Pack_backend.query_all store "everything" in
      match all with
      | [ decoded ] ->
          Alcotest.(check int) "same arity" (List.length f.Fact.arguments) (List.length decoded.Fact.arguments);
          Alcotest.(check bool) "all arguments equal"
            true
            (List.for_all2 Value.equal f.Fact.arguments decoded.Fact.arguments);
          Lwt.return_unit
      | _ -> Alcotest.fail "expected exactly one fact")

let () =
  Alcotest.run "BeingDB Storage"
    [
      ( "Equality lookup",
        [
          Alcotest.test_case "every position" `Quick test_equality_lookup_every_position;
          Alcotest.test_case "typed (decimal canonicalization)" `Quick test_equality_lookup_typed;
        ] );
      ( "Range scans",
        [
          Alcotest.test_case "integer range" `Quick test_integer_range_scan;
          Alcotest.test_case "integer negative-to-positive ordering" `Quick
            test_integer_negative_to_positive_ordering;
          Alcotest.test_case "year range" `Quick test_year_range_scan;
          Alcotest.test_case "date range" `Quick test_date_range_scan;
          Alcotest.test_case "instant range" `Quick test_instant_range_scan;
        ] );
      ("Mixed-type branches", [ Alcotest.test_case "mixed types" `Quick test_mixed_type_index_branches ]);
      ( "Fact reconstruction",
        [ Alcotest.test_case "full typed fact" `Quick test_full_typed_fact_reconstruction ] );
    ]
