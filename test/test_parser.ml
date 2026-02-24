(** Parsing tests for BeingDB *)

(* Helper: Create testable for arg_value *)
let arg_value_testable =
  Alcotest.testable Beingdb.Types.pp_arg_value (=)

let arg_value_list_testable =
  Alcotest.list arg_value_testable

let fact_testable =
  Alcotest.pair Alcotest.string arg_value_list_testable

let test_parse_fact () =
  let open Beingdb.Parse_predicate in
  let open Beingdb.Types in
  
  (* Test simple fact *)
  let fact1 = "created(tina_keane, she)." in
  let result1 = parse_fact fact1 in
  Alcotest.(check (option fact_testable))
    "parse simple fact" 
    (Some ("created", [Atom "tina_keane"; Atom "she"]))
    result1;
  
  (* Test fact without trailing dot *)
  let fact2 = "shown_in(she, rewind_exhibition_1995)" in
  let result2 = parse_fact fact2 in
  Alcotest.(check (option fact_testable))
    "parse fact without dot"
    (Some ("shown_in", [Atom "she"; Atom "rewind_exhibition_1995"]))
    result2;
  
  (* Test fact with spaces *)
  let fact3 = "created( tina_keane , she )." in
  let result3 = parse_fact fact3 in
  Alcotest.(check (option fact_testable))
    "parse fact with spaces"
    (Some ("created", [Atom "tina_keane"; Atom "she"]))
    result3;
  
  (* Test three-argument fact *)
  let fact4 = "relationship(subject, predicate, object)." in
  let result4 = parse_fact fact4 in
  Alcotest.(check (option fact_testable))
    "parse three-argument fact"
    (Some ("relationship", [Atom "subject"; Atom "predicate"; Atom "object"]))
    result4;
  
  (* Test single-argument fact *)
  let fact5 = "active(user123)." in
  let result5 = parse_fact fact5 in
  Alcotest.(check (option fact_testable))
    "parse single-argument fact"
    (Some ("active", [Atom "user123"]))
    result5;
  
  (* Test fact with quoted strings *)
  let fact6 = "keyword(doc_456, \"neural networks\")." in
  let result6 = parse_fact fact6 in
  Alcotest.(check (option fact_testable))
    "parse fact with quoted string"
    (Some ("keyword", [Atom "doc_456"; String "neural networks"]))
    result6;
  
  (* Test fact with multiple strings *)
  let fact6b = "note(author, \"First string\", \"Second string\")." in
  let result6b = parse_fact fact6b in
  Alcotest.(check (option fact_testable))
    "parse fact with multiple strings"
    (Some ("note", [Atom "author"; String "First string"; String "Second string"]))
    result6b;
  
  (* Test invalid facts *)
  let fact7 = "not_a_fact" in
  let result7 = parse_fact fact7 in
  Alcotest.(check (option fact_testable))
    "parse invalid fact (no parens)"
    None
    result7;
  
  (* Parser is lenient with unclosed parens - it just treats content as args *)
  let fact8 = "invalid(" in
  let result8 = parse_fact fact8 in
  Alcotest.(check (option fact_testable))
    "parse fact with unclosed parens (lenient parser)"
    (Some ("invalid", []))
    result8;
  
  let fact9 = "" in
  let result9 = parse_fact fact9 in
  Alcotest.(check (option fact_testable))
    "parse empty string"
    None
    result9

let () =
  Alcotest.run "BeingDB Parser" [
    "Parse", [
      Alcotest.test_case "parse_fact" `Quick test_parse_fact;
    ];
  ]
