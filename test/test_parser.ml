(** Parsing and canonicalization tests for BeingDB's typed literal syntax. *)

open Beingdb

let value_testable =
  Alcotest.testable
    (fun fmt v -> Format.fprintf fmt "%s:%s" (Value.type_name v) (Value.canonical_string v))
    (fun a b -> Value.type_name a = Value.type_name b && Value.equal a b)

let fact_testable =
  Alcotest.testable
    (fun fmt ((predicate, args) : string * Value.t list) ->
      Format.fprintf fmt "%s(%s)" predicate (String.concat "," (List.map Value.canonical_string args)))
    (fun ((p1, a1) : string * Value.t list) ((p2, a2) : string * Value.t list) ->
      p1 = p2 && (try List.for_all2 Value.equal a1 a2 with Invalid_argument _ -> false))

let parse_ok fact =
  match Parse_predicate.parse_fact fact with
  | Some (Ok v) -> Some v
  | Some (Error _) -> None
  | None -> None

(* --- basic fact parsing --- *)

let test_parse_atoms () =
  Alcotest.(check (option fact_testable))
    "atoms" (Some ("created", [ Value.Atom "tina_keane"; Value.Atom "she" ]))
    (parse_ok "created(tina_keane, she).")

let test_parse_no_trailing_dot () =
  Alcotest.(check (option fact_testable))
    "no dot" (Some ("shown_in", [ Value.Atom "she"; Value.Atom "rewind_exhibition_1995" ]))
    (parse_ok "shown_in(she, rewind_exhibition_1995)")

let test_parse_whitespace () =
  Alcotest.(check (option fact_testable))
    "whitespace" (Some ("created", [ Value.Atom "tina_keane"; Value.Atom "she" ]))
    (parse_ok "created( tina_keane , she ).")

let test_parse_string () =
  Alcotest.(check (option fact_testable))
    "string" (Some ("keyword", [ Value.Atom "doc_456"; Value.String "neural networks" ]))
    (parse_ok "keyword(doc_456, \"neural networks\").")

let test_parse_escaped_string () =
  Alcotest.(check (option fact_testable))
    "escaped string"
    (Some ("note", [ Value.String "line1\nline2\ttab\"quote" ]))
    (parse_ok "note(\"line1\\nline2\\ttab\\\"quote\").")

let test_parse_lang_string () =
  Alcotest.(check (option fact_testable))
    "lang string"
    (Some ("label", [ Value.Atom "alice_smith"; Value.Lang_string { value = "Alice Smith"; language = "en" } ]))
    (parse_ok "label(alice_smith, \"Alice Smith\"@en).")

let test_parse_boolean () =
  Alcotest.(check (option fact_testable))
    "boolean" (Some ("reviewed", [ Value.Atom "assertion_1"; Value.Boolean true ]))
    (parse_ok "reviewed(assertion_1, true).")

let test_parse_integer () =
  Alcotest.(check (option fact_testable))
    "integer" (Some ("birth_number", [ Value.Atom "alice_smith"; Value.Integer 1972L ]))
    (parse_ok "birth_number(alice_smith, 1972).")

let test_parse_negative_integer () =
  Alcotest.(check (option fact_testable))
    "negative integer" (Some ("delta", [ Value.Integer (-42L) ]))
    (parse_ok "delta(-42).")

let test_parse_decimal () =
  Alcotest.(check (option fact_testable))
    "decimal"
    (Some ("confidence", [ Value.Atom "assertion_1"; Value.Decimal (Decimal.make 92L 2) ]))
    (parse_ok "confidence(assertion_1, 0.92).")

let test_parse_negative_decimal () =
  match parse_ok "delta(-3.50)." with
  | Some ("delta", [ Value.Decimal d ]) -> Alcotest.(check string) "value" "-3.5" (Decimal.to_string d)
  | _ -> Alcotest.fail "expected a decimal"

let test_distinguish_integer_year_string_atom () =
  (* 1979 (integer), @1979 (year), "1979" (string), year_1979 (atom) must
     all be distinct types. *)
  match
    ( parse_ok "v(1979).",
      parse_ok "v(@1979).",
      parse_ok "v(\"1979\").",
      parse_ok "v(year_1979)." )
  with
  | Some (_, [ a ]), Some (_, [ b ]), Some (_, [ c ]), Some (_, [ d ]) ->
      Alcotest.(check bool) "integer<>year" false (Value.equal a b);
      Alcotest.(check bool) "integer<>string" false (Value.equal a c);
      Alcotest.(check bool) "integer<>atom" false (Value.equal a d);
      Alcotest.(check bool) "year<>string" false (Value.equal b c);
      Alcotest.(check string) "types" "integer,year,string,atom"
        (String.concat "," [ Value.type_name a; Value.type_name b; Value.type_name c; Value.type_name d ])
  | _ -> Alcotest.fail "expected all four facts to parse"

let test_parse_year () =
  Alcotest.(check (option fact_testable)) "year" (Some ("birth_year", [ Value.Atom "alice_smith"; Value.Year 1972 ]))
    (parse_ok "birth_year(alice_smith, @1972).")

let test_parse_year_month () =
  match parse_ok "published(issue_1, @1972-05)." with
  | Some (_, [ _; Value.Year_month { year; month } ]) ->
      Alcotest.(check int) "year" 1972 year;
      Alcotest.(check int) "month" 5 month
  | _ -> Alcotest.fail "expected a year_month"

let test_parse_date () =
  match parse_ok "opened(exhibition_1, @1972-05-14)." with
  | Some (_, [ _; Value.Date { year; month; day } ]) ->
      Alcotest.(check int) "year" 1972 year;
      Alcotest.(check int) "month" 5 month;
      Alcotest.(check int) "day" 14 day
  | _ -> Alcotest.fail "expected a date"

let test_parse_leap_year_date () =
  Alcotest.(check bool) "2024-02-29 valid" true (parse_ok "d(@2024-02-29)." <> None);
  Alcotest.(check bool) "2023-02-29 invalid" true (parse_ok "d(@2023-02-29)." = None)

let test_parse_invalid_date () =
  Alcotest.(check bool) "month 13 invalid" true (parse_ok "d(@1979-13-01)." = None);
  Alcotest.(check bool) "day 32 invalid" true (parse_ok "d(@1979-01-32)." = None)

let test_parse_instant_utc () =
  match parse_ok "captured_at(capture_1, @2026-08-06T12:15:00Z)." with
  | Some (_, [ _; Value.Instant t ]) -> Alcotest.(check string) "canonical" "2026-08-06T12:15:00Z" (Calendar.format_instant t)
  | _ -> Alcotest.fail "expected an instant"

let test_parse_instant_with_offset_normalizes_to_utc () =
  match (parse_ok "d(@2026-08-06T12:15:00+01:00).", parse_ok "d(@2026-08-06T11:15:00Z).") with
  | Some (_, [ Value.Instant a ]), Some (_, [ Value.Instant b ]) ->
      Alcotest.(check bool) "same UTC instant" true (Calendar.equal_instant a b)
  | _ -> Alcotest.fail "expected instants"

let test_parse_malformed_instant () =
  Alcotest.(check bool) "missing zone" true (parse_ok "d(@2026-08-06T12:15:00)." = None);
  Alcotest.(check bool) "missing time" true (parse_ok "d(@2026-08-06Z)." = None)

let test_parse_uri () =
  Alcotest.(check (option fact_testable))
    "uri"
    (Some ("homepage", [ Value.Atom "organisation_1"; Value.Uri "https://example.org/" ]))
    (parse_ok "homepage(organisation_1, <https://example.org/>).")

let test_parse_malformed_uri () =
  Alcotest.(check bool) "no scheme" true (parse_ok "d(<not a uri>)." = None)

let test_parse_invalid_language_tag () =
  Alcotest.(check bool) "bad tag" true (parse_ok "label(x, \"hi\"@1)." = None)

let test_parse_comment_and_blank () =
  Alcotest.(check (option fact_testable)) "comment" None (parse_ok "% just a comment");
  Alcotest.(check (option fact_testable)) "blank" None (parse_ok "")

let test_parse_not_a_fact () =
  Alcotest.(check (option fact_testable)) "no parens" None (parse_ok "not_a_fact")

(* --- canonicalization --- *)

let test_decimal_canonical_equal () =
  let a = Decimal.of_string "0.9" and b = Decimal.of_string "0.90" and c = Decimal.of_string "0.900" in
  match (a, b, c) with
  | Ok a, Ok b, Ok c ->
      Alcotest.(check bool) "0.9 = 0.90" true (Decimal.equal a b);
      Alcotest.(check bool) "0.9 = 0.900" true (Decimal.equal a c);
      Alcotest.(check string) "canonical" "0.9" (Decimal.to_string a);
      Alcotest.(check string) "canonical b" "0.9" (Decimal.to_string b);
      Alcotest.(check string) "canonical c" "0.9" (Decimal.to_string c)
  | _ -> Alcotest.fail "expected valid decimals"

let test_decimal_ordering () =
  match (Decimal.of_string "1.5", Decimal.of_string "1.50000001") with
  | Ok a, Ok b -> Alcotest.(check bool) "1.5 < 1.50000001" true (Decimal.compare a b < 0)
  | _ -> Alcotest.fail "expected valid decimals"

let test_instant_offsets_canonicalize_identically () =
  match (Calendar.parse_instant "2019-06-01T09:00:00+02:00", Calendar.parse_instant "2019-06-01T07:00:00Z") with
  | Ok a, Ok b -> Alcotest.(check string) "same encoding" (Calendar.format_instant a) (Calendar.format_instant b)
  | _ -> Alcotest.fail "expected valid instants"

let test_fact_id_deterministic () =
  let f = Fact.make "created" [ Value.Atom "a"; Value.Atom "b" ] in
  Alcotest.(check string) "stable" (Fact.fact_id f) (Fact.fact_id f)

let test_fact_id_type_distinct () =
  let f1 = Fact.make "value" [ Value.Atom "item"; Value.Integer 1979L ] in
  let f2 = Fact.make "value" [ Value.Atom "item"; Value.Year 1979 ] in
  let f3 = Fact.make "value" [ Value.Atom "item"; Value.String "1979" ] in
  let ids = [ Fact.fact_id f1; Fact.fact_id f2; Fact.fact_id f3 ] in
  Alcotest.(check int) "all distinct" 3 (List.length (List.sort_uniq String.compare ids))

let test_fact_encode_decode_roundtrip () =
  let f =
    Fact.make "captured_at"
      [
        Value.Atom "capture_1";
        (match Calendar.parse_instant "2026-08-06T12:15:00Z" with Ok t -> Value.Instant t | Error e -> failwith e);
      ]
  in
  match Fact.decode (Fact.encode f) with
  | Ok f' ->
      Alcotest.(check string) "predicate" f.predicate f'.predicate;
      Alcotest.(check bool) "args equal" true (List.for_all2 Value.equal f.arguments f'.arguments)
  | Error e -> Alcotest.fail e

let () =
  Alcotest.run "BeingDB Parser"
    [
      ( "Parse facts",
        [
          Alcotest.test_case "atoms" `Quick test_parse_atoms;
          Alcotest.test_case "no trailing dot" `Quick test_parse_no_trailing_dot;
          Alcotest.test_case "whitespace" `Quick test_parse_whitespace;
          Alcotest.test_case "string" `Quick test_parse_string;
          Alcotest.test_case "escaped string" `Quick test_parse_escaped_string;
          Alcotest.test_case "lang string" `Quick test_parse_lang_string;
          Alcotest.test_case "boolean" `Quick test_parse_boolean;
          Alcotest.test_case "integer" `Quick test_parse_integer;
          Alcotest.test_case "negative integer" `Quick test_parse_negative_integer;
          Alcotest.test_case "decimal" `Quick test_parse_decimal;
          Alcotest.test_case "negative decimal" `Quick test_parse_negative_decimal;
          Alcotest.test_case "integer/year/string/atom distinct" `Quick test_distinguish_integer_year_string_atom;
          Alcotest.test_case "year" `Quick test_parse_year;
          Alcotest.test_case "year_month" `Quick test_parse_year_month;
          Alcotest.test_case "date" `Quick test_parse_date;
          Alcotest.test_case "leap year date" `Quick test_parse_leap_year_date;
          Alcotest.test_case "invalid date" `Quick test_parse_invalid_date;
          Alcotest.test_case "instant utc" `Quick test_parse_instant_utc;
          Alcotest.test_case "instant offset normalizes" `Quick test_parse_instant_with_offset_normalizes_to_utc;
          Alcotest.test_case "malformed instant" `Quick test_parse_malformed_instant;
          Alcotest.test_case "uri" `Quick test_parse_uri;
          Alcotest.test_case "malformed uri" `Quick test_parse_malformed_uri;
          Alcotest.test_case "invalid language tag" `Quick test_parse_invalid_language_tag;
          Alcotest.test_case "comment and blank" `Quick test_parse_comment_and_blank;
          Alcotest.test_case "not a fact" `Quick test_parse_not_a_fact;
        ] );
      ( "Canonicalization",
        [
          Alcotest.test_case "decimal canonical equal" `Quick test_decimal_canonical_equal;
          Alcotest.test_case "decimal ordering" `Quick test_decimal_ordering;
          Alcotest.test_case "instant offsets canonicalize identically" `Quick
            test_instant_offsets_canonicalize_identically;
          Alcotest.test_case "fact id deterministic" `Quick test_fact_id_deterministic;
          Alcotest.test_case "fact id type distinct" `Quick test_fact_id_type_distinct;
          Alcotest.test_case "fact encode/decode roundtrip" `Quick test_fact_encode_decode_roundtrip;
        ] );
    ]

let _ = value_testable

