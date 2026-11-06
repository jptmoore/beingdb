(** Value_lookup over the in-memory store: word splitting, exact, label,
    alias, fuzzy and partial matches, ambiguity, the partial-match cap,
    and [about]. Portable runtime only. *)

open Beingdb_runtime
module Env = Query_environment.Make (Memory_store)
module Lookup = Value_lookup.Make (Memory_store)
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
       ~arguments:(Some (List.map (fun (role, semantic_type) -> { Predicate_declaration.role; semantic_type }) roles))
       ~description:(Some description))

let store =
  lazy
    (let s = Memory_store.create () in
     let add ?declaration name rows = Memory_store.add_predicate ?declaration s name (List.map (Fact.make name) rows) in
     add
       ~declaration:(declare [ ("Work", None); ("Artist", Some "person") ] "Relates a work to the artist who made it.")
       "created_by"
       [
         [ atom "mandala"; atom "judith_goddard" ];
         [ atom "time_and_motion"; atom "judith_goddard" ];
         [ atom "tape_tape"; atom "david_hall" ];
         [ atom "this_is_a_tv"; atom "david_hall" ];
         [ atom "pieces"; atom "david_critchley" ];
       ];
     add "person" [ [ atom "judith_goddard" ]; [ atom "david_hall" ] ];
     add "made_at" [ [ atom "mandala"; atom "oval_house" ] ];
     add "shown_at" [ [ atom "mandala"; atom "tate" ]; [ atom "tape_tape"; atom "about_time" ] ];
     add "lost" [ [ atom "pieces_i_never_did" ] ];
     add "titled" [ [ atom "mandala"; Value.String "Hey Bud" ] ];
     add "held" [ [ atom "robert_mortain"; atom "exeter" ] ];
     add "label"
       [
         [ atom "judith_goddard"; Value.String "Judith Goddard" ];
         [ atom "robert_mortain"; Value.String "Robert, Count of Mortain" ];
       ];
     add "alias" [ [ atom "exeter"; Value.String "Execestre" ] ];
     (* Many values sharing one word: a partial match on it is too vague. *)
     add "reel" (List.init 60 (fun k -> [ atom (Printf.sprintf "reel_tape_%d" k) ]));
     s)

let env = lazy (run (Env.build (Lazy.force store)))
let index = lazy (run (Lookup.build_index (Lazy.force store) (Lazy.force env)))

let resolve text =
  match Lookup.resolve (Lazy.force env) (Lazy.force index) text with Ok json -> json | Error (_, m) -> Alcotest.fail m

let mentions json = U.(json |> member "mentions" |> to_list)
let str field j = U.(j |> member field |> to_string)
let int field j = U.(j |> member field |> to_int)
let candidates m = U.(m |> member "candidates" |> to_list)
let literals m = List.map (str "literal") (candidates m)

let find_mention json text =
  match List.find_opt (fun m -> str "text" m = text) (mentions json) with
  | Some m -> m
  | None -> Alcotest.failf "no mention %S in %s" text (Yojson.Safe.to_string json)

let test_exact () =
  let json = resolve "Which works did Judith Goddard's friends make at Oval House?" in
  Alcotest.(check (list string)) "mentions" [ "Judith Goddard"; "Oval House" ] (List.map (str "text") (mentions json));
  let m = find_mention json "Judith Goddard" in
  Alcotest.(check string) "match" "exact" (str "match" m);
  Alcotest.(check (list string)) "candidate" [ "judith_goddard" ] (literals m);
  let c = List.hd (candidates m) in
  Alcotest.(check string) "label" "Judith Goddard" (str "label" c);
  Alcotest.(check int) "facts (labels excluded)" 3 (int "facts" c);
  let created = List.find (fun o -> str "predicate" o = "created_by") U.(c |> member "occurs" |> to_list) in
  Alcotest.(check int) "position" 1 (int "position" created);
  Alcotest.(check string) "role" "Artist" (str "role" created);
  Alcotest.(check string) "semantic type" "person" (str "semanticType" created);
  Alcotest.(check int) "byte offsets" 16 (int "start" m);
  Alcotest.(check int) "end" 30 (int "end" m)

let test_fuzzy () =
  let m = find_mention (resolve "Who is judith godard?") "judith godard" in
  Alcotest.(check string) "match" "fuzzy" (str "match" m);
  Alcotest.(check (list string)) "candidate" [ "judith_goddard" ] (literals m);
  (* Words are compared one by one; short words must match exactly. *)
  let json = resolve "Tell me about Tate" in
  Alcotest.(check (list string)) "not about_time" [ "Tate" ] (List.map (str "text") (mentions json));
  Alcotest.(check (list string)) "tate" [ "tate" ] (literals (find_mention json "Tate"))

let test_partial_ambiguous () =
  let m = find_mention (resolve "Tell me about David") "David" in
  Alcotest.(check string) "match" "partial" (str "match" m);
  Alcotest.(check int) "candidateCount" 2 (int "candidateCount" m);
  Alcotest.(check (list string)) "most facts first" [ "david_hall"; "david_critchley" ] (literals m);
  (* Partial matches need a name cue: a capitalised word that does not start
     a sentence, or a text that is only the name. *)
  Alcotest.(check int) "lowercase in a sentence" 0 (List.length (mentions (resolve "tell me about david")));
  Alcotest.(check (list string)) "only the name" [ "david_hall"; "david_critchley" ] (literals (find_mention (resolve "david") "david"));
  Alcotest.(check int) "ordinary words" 0 (List.length (mentions (resolve "Never. Did they? Which did I never see")))

let test_label_and_alias () =
  let m = find_mention (resolve "What did Robert, Count of Mortain hold?") "Robert, Count of Mortain" in
  Alcotest.(check string) "label" "label" (str "match" m);
  Alcotest.(check (list string)) "candidate" [ "robert_mortain" ] (literals m);
  let m = find_mention (resolve "Lands of the Count of Mortain") "Count of Mortain" in
  Alcotest.(check string) "partial label" "partial" (str "match" m);
  Alcotest.(check (list string)) "candidate" [ "robert_mortain" ] (literals m);
  let m = find_mention (resolve "Who held Execestre?") "Execestre" in
  Alcotest.(check string) "alias" "alias" (str "match" m);
  Alcotest.(check (list string)) "candidate" [ "exeter" ] (literals m)

let test_strings () =
  let m = find_mention (resolve "Who made Hey Bud?") "Hey Bud" in
  Alcotest.(check (list string)) "string literal" [ "\"Hey Bud\"" ] (literals m);
  let c = List.hd (candidates m) in
  Alcotest.(check string) "typed value" "string" U.(c |> member "value" |> member "type" |> to_string)

let test_no_vague_or_short_matches () =
  Alcotest.(check int) "common word, short words, numbers" 0 (List.length (mentions (resolve "Which tape is in 1979 or at it?")));
  match Lookup.resolve (Lazy.force env) (Lazy.force index) (String.make (Value_lookup.max_text_length + 1) 'a') with
  | Error (code, _) -> Alcotest.(check string) "too long" "text_too_long" code
  | Ok _ -> Alcotest.fail "expected text_too_long"

let about ?limit literal =
  run (Lookup.about ?limit (Lazy.force store) (Lazy.force env) (Result.get_ok (Value_lookup.parse_value literal)))

let test_about () =
  let json = about ~limit:1 "judith_goddard" in
  Alcotest.(check string) "label" "Judith Goddard" (str "label" json);
  Alcotest.(check int) "facts" 3 (int "facts" json);
  let groups = U.(json |> member "predicates" |> to_list) in
  Alcotest.(check (list string)) "groups" [ "created_by"; "person" ] (List.map (str "predicate") groups);
  let created = List.hd groups in
  Alcotest.(check int) "count" 2 (int "count" created);
  Alcotest.(check int) "limited" 1 (List.length U.(created |> member "facts" |> to_list));
  Alcotest.(check bool) "hasMore" true U.(created |> member "hasMore" |> to_bool);
  Alcotest.(check (list string)) "roles" [ "Work"; "Artist" ] U.(created |> member "roles" |> to_list |> List.map to_string);
  Alcotest.(check string) "description" "Relates a work to the artist who made it." (str "description" created);
  let exeter = about "exeter" in
  Alcotest.(check (list string)) "aliases" [ "Execestre" ] U.(exeter |> member "aliases" |> to_list |> List.map to_string);
  let hey = about "\"Hey Bud\"" in
  Alcotest.(check int) "string value" 1 (int "facts" hey);
  let unknown = about "nobody" in
  Alcotest.(check int) "unknown value" 0 (int "facts" unknown);
  Alcotest.(check int) "no groups" 0 (List.length U.(unknown |> member "predicates" |> to_list))

let test_parse_value () =
  Alcotest.(check bool) "year" true (Value_lookup.parse_value "@1979" = Ok (Value.Year 1979));
  Alcotest.(check bool) "string" true (Value_lookup.parse_value "\"Hey Bud\"" = Ok (Value.String "Hey Bud"));
  Alcotest.(check bool) "two literals" true (Result.is_error (Value_lookup.parse_value "a b"))

let () =
  Alcotest.run "Value lookup"
    [
      ( "resolve",
        [
          Alcotest.test_case "exact" `Quick test_exact;
          Alcotest.test_case "fuzzy" `Quick test_fuzzy;
          Alcotest.test_case "partial and ambiguous" `Quick test_partial_ambiguous;
          Alcotest.test_case "label and alias" `Quick test_label_and_alias;
          Alcotest.test_case "string values" `Quick test_strings;
          Alcotest.test_case "no vague or short matches" `Quick test_no_vague_or_short_matches;
        ] );
      ("about", [ Alcotest.test_case "about" `Quick test_about; Alcotest.test_case "parse_value" `Quick test_parse_value ]);
    ]
