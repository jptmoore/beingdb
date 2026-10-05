(** Predicate declarations: source parsing, manifest storage and
    backwards compatibility, query-environment introspection and
    fingerprinting, the detailed predicates JSON, and the Git -> compile
    -> pack path. *)

open Beingdb
module Mem_env = Beingdb_runtime.Query_environment.Make (Memory_store)

let run p = Lwt_main.run p

let temp_dir name =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "beingdb_decl_test_%s_%d_%d" name (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  dir

let cleanup dir = ignore (Unix.system (Printf.sprintf "rm -rf %s" (Filename.quote dir)))

let decl ?description args =
  let arguments = List.map (fun (role, semantic_type) -> { Predicate_declaration.role; semantic_type }) args in
  match Predicate_declaration.make ~arguments:(Some arguments) ~description with Ok d -> d | Error e -> Alcotest.fail e

let description_only text =
  match Predicate_declaration.make ~arguments:None ~description:(Some text) with Ok d -> d | Error e -> Alcotest.fail e

let created_by_decl =
  decl ~description:"Relates a work to the person who created it."
    [ ("Work", Some "work"); ("Creator", Some "person") ]

let atoms predicate rows = List.map (fun args -> Fact.make predicate (List.map (fun a -> Value.Atom a) args)) rows
let created_by_facts = atoms "created_by" [ [ "work1"; "alice" ]; [ "work2"; "bob" ] ]
let person_facts = atoms "person" [ [ "alice" ]; [ "bob" ] ]
let declared_args (d : Predicate_declaration.t) = Option.value d.arguments ~default:[]
let roles d = List.map (fun (a : Predicate_declaration.argument) -> a.role) (declared_args d)
let semantic_types d = List.map (fun (a : Predicate_declaration.argument) -> a.semantic_type) (declared_args d)

(* --- source parsing --- *)

let test_extract_full () =
  let items, warnings =
    Parse_declaration.extract
      [
        "% Work creation relationships";
        "%! created_by(Work:work, Creator:person)";
        "%";
        "%   Relates a work to the person";
        "%   who created it.";
        "%";
        "%   Each work may have several creators.";
        "created_by(work1, alice).";
      ]
  in
  Alcotest.(check (list string)) "no warnings" [] warnings;
  match items with
  | [ { name; declaration = d; line } ] ->
      Alcotest.(check string) "name" "created_by" name;
      Alcotest.(check int) "line" 2 line;
      Alcotest.(check (list string)) "roles" [ "Work"; "Creator" ] (roles d);
      Alcotest.(check (list (option string))) "semantic types" [ Some "work"; Some "person" ] (semantic_types d);
      Alcotest.(check (option string)) "description paragraphs"
        (Some "Relates a work to the person who created it.\n\nEach work may have several creators.")
        d.description
  | _ -> Alcotest.fail "expected exactly one declaration"

let test_extract_minimal () =
  let items, warnings = Parse_declaration.extract [ "%! knows(Person, Other)."; ""; "% not part of it"; "knows(a, b)." ] in
  Alcotest.(check (list string)) "no warnings" [] warnings;
  match items with
  | [ { declaration = d; _ } ] ->
      Alcotest.(check (list string)) "roles" [ "Person"; "Other" ] (roles d);
      Alcotest.(check (list (option string))) "no semantic types" [ None; None ] (semantic_types d);
      Alcotest.(check (option string)) "blank line ends the block" None d.description
  | _ -> Alcotest.fail "expected exactly one declaration"

let test_plain_comments_are_not_declarations () =
  let items, warnings = Parse_declaration.extract [ "% created_by(Work, Person)"; "# note"; "created_by(w, p)." ] in
  Alcotest.(check int) "no declarations" 0 (List.length items);
  Alcotest.(check (list string)) "no warnings" [] warnings

(* Each authoring form, compiled for a 2-argument predicate: the stored
   declaration (manifest JSON) or None, and the number of warnings. *)
let progressive_forms =
  let desc = "% Relates a work to the artist or creator who made it." in
  let d = {|"description":"Relates a work to the artist or creator who made it."|} in
  [
    ("no metadata", [], None);
    ("plain % comment is not metadata", [ desc ], None);
    ("description only", [ "%! created_by"; desc ], Some ("{" ^ d ^ "}"));
    ("roles only", [ "%! created_by(Work, Artist)" ], Some {|{"arguments":[{"role":"Work"},{"role":"Artist"}]}|});
    ( "roles + description",
      [ "%! created_by(Work, Artist)"; desc ],
      Some ({|{"arguments":[{"role":"Work"},{"role":"Artist"}],|} ^ d ^ "}") );
    ( "roles + semantic types",
      [ "%! created_by(Work:work, Artist:person)" ],
      Some {|{"arguments":[{"role":"Work","semantic_type":"work"},{"role":"Artist","semantic_type":"person"}]}|} );
    ( "roles + semantic types + description",
      [ "%! created_by(Work:work, Artist:person)"; desc ],
      Some ({|{"arguments":[{"role":"Work","semantic_type":"work"},{"role":"Artist","semantic_type":"person"}],|} ^ d ^ "}") );
    ( "semantic type on some arguments only",
      [ "%! created_by(Work:work, Artist)" ],
      Some {|{"arguments":[{"role":"Work","semantic_type":"work"},{"role":"Artist"}]}|} );
  ]

let test_progressive_forms () =
  List.iter
    (fun (label, header, expected) ->
      let items, warnings = Parse_declaration.extract (header @ [ {|created_by("Work A", "Artist A").|} ]) in
      let d, select_warnings = Parse_declaration.select ~predicate:"created_by" ~arity:2 items in
      Alcotest.(check (list string)) (label ^ ": no warnings") [] (warnings @ select_warnings);
      Alcotest.(check (option string)) label expected
        (Option.map (fun d -> Yojson.Safe.to_string (Predicate_declaration.to_json d)) d))
    progressive_forms

let test_description_only_any_arity () =
  let items, _ = Parse_declaration.extract [ "%! created_by"; "% Text." ] in
  List.iter
    (fun arity ->
      let d, warnings = Parse_declaration.select ~predicate:"created_by" ~arity items in
      Alcotest.(check bool) "applies at any arity" true (d <> None);
      Alcotest.(check (list string)) "no warnings" [] warnings)
    [ 1; 2; 3 ]

let test_invalid_declarations_warn () =
  let bad =
    [
      "%! created_by(+Work, -Person) is det";
      "%! created_by(work, Person)";
      "%! created_by(Work, Work)";
      "%! created_by(Work:Person, X)";
      "%! Created_by(Work, X)";
      "%! created_by";
      "%! created_by/2";
      "%! created_by(Work:)";
      "%! created_by(Work";
    ]
  in
  List.iter
    (fun line ->
      let items, warnings = Parse_declaration.extract [ line ] in
      Alcotest.(check int) ("ignored: " ^ line) 0 (List.length items);
      Alcotest.(check int) ("one warning: " ^ line) 1 (List.length warnings))
    bad

let test_select () =
  let items, _ =
    Parse_declaration.extract
      [ "%! other(X)"; "%! created_by(Work, Creator)"; "%  First."; "%! created_by(A, B)"; "%  Second." ]
  in
  let d, warnings = Parse_declaration.select ~predicate:"created_by" ~arity:2 items in
  (match d with
  | Some d -> Alcotest.(check (option string)) "first declaration wins" (Some "First.") d.description
  | None -> Alcotest.fail "expected a declaration");
  Alcotest.(check int) "repeat and foreign declaration warned" 2 (List.length warnings);
  let d, warnings = Parse_declaration.select ~predicate:"created_by" ~arity:3 items in
  Alcotest.(check bool) "arity mismatch ignored" true (d = None);
  let contains s sub =
    let n = String.length sub in
    let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool) "arity mismatch warned" true (List.exists (fun w -> contains w "the facts have 3") warnings)

(* --- typed record and manifest encoding --- *)

let test_declaration_json_roundtrip () =
  let json = Predicate_declaration.to_json created_by_decl in
  (match Predicate_declaration.of_json json with
  | Ok d -> Alcotest.(check bool) "roundtrip" true (d = created_by_decl)
  | Error e -> Alcotest.fail e);
  let bare = decl [ ("X", None) ] in
  Alcotest.(check string) "optional fields omitted" {|{"arguments":[{"role":"X"}]}|}
    (Yojson.Safe.to_string (Predicate_declaration.to_json bare));
  Alcotest.(check string) "signature" "created_by(Work:work, Creator:person)"
    (Predicate_declaration.signature "created_by" created_by_decl);
  Alcotest.(check bool) "blank description is None" true
    ((decl ~description:"   " [ ("X", None) ]).description = None);
  let text_only = description_only "Relates a work to its creator." in
  Alcotest.(check string) "description-only omits arguments" {|{"description":"Relates a work to its creator."}|}
    (Yojson.Safe.to_string (Predicate_declaration.to_json text_only));
  (match Predicate_declaration.of_json (Predicate_declaration.to_json text_only) with
  | Ok d -> Alcotest.(check bool) "description-only roundtrip" true (d = text_only)
  | Error e -> Alcotest.fail e);
  Alcotest.(check (option int)) "description-only has no declared arity" None (Predicate_declaration.arity text_only);
  Alcotest.(check string) "description-only signature" "created_by" (Predicate_declaration.signature "created_by" text_only);
  Alcotest.(check bool) "empty declaration rejected" true
    (Result.is_error (Predicate_declaration.make ~arguments:None ~description:(Some " ")));
  Alcotest.(check bool) "empty declaration JSON rejected" true
    (Result.is_error (Predicate_declaration.of_json (`Assoc [])))

let legacy_manifest_json =
  {|{"arity":2,"fact_count":2,"positions":[{"atom":{"count":2,"distinct_count":2,"min":"work1","max":"work1"}},{"atom":{"count":2,"distinct_count":2,"min":"alice","max":"alice"}}]}|}

let test_manifest_compatibility () =
  let plain = Manifest.compute created_by_facts in
  Alcotest.(check string) "undeclared manifest JSON unchanged" legacy_manifest_json
    (Yojson.Safe.to_string (Manifest.to_json plain));
  (match Manifest.of_json (Yojson.Safe.from_string legacy_manifest_json) with
  | Ok m -> Alcotest.(check bool) "legacy manifest has no declaration" true (m.declaration = None)
  | Error e -> Alcotest.fail e);
  let declared = Manifest.compute ~declaration:created_by_decl created_by_facts in
  (match Manifest.of_json (Manifest.to_json declared) with
  | Ok m -> Alcotest.(check bool) "declared manifest roundtrip" true (m = declared)
  | Error e -> Alcotest.fail e);
  let malformed =
    String.sub legacy_manifest_json 0 (String.length legacy_manifest_json - 1) ^ {|,"declaration":{"arguments":7}}|}
  in
  match Manifest.of_json (Yojson.Safe.from_string malformed) with
  | Ok m ->
      Alcotest.(check bool) "malformed declaration reads as None" true (m.declaration = None);
      Alcotest.(check int) "rest of manifest intact" 2 m.fact_count
  | Error e -> Alcotest.fail e

(* --- query environment --- *)

let memory_store ?declaration () =
  let t = Memory_store.create () in
  Memory_store.add_predicate ?declaration t "created_by" created_by_facts;
  Memory_store.add_predicate t "person" person_facts;
  t

let env_of store = run (Mem_env.build store)

let test_environment_fields () =
  let env = env_of (memory_store ~declaration:created_by_decl ()) in
  (match Query_environment.find env "created_by" with
  | None -> Alcotest.fail "created_by missing"
  | Some p ->
      Alcotest.(check string) "name" "created_by" p.name;
      Alcotest.(check int) "arity" 2 p.arity;
      Alcotest.(check (option string)) "description" (Some "Relates a work to the person who created it.") p.description;
      Alcotest.(check (list (option string))) "roles" [ Some "Work"; Some "Creator" ]
        (List.map (fun (a : Query_environment.argument_signature) -> a.role) p.arguments);
      Alcotest.(check (list (option string))) "semantic types" [ Some "work"; Some "person" ]
        (List.map (fun (a : Query_environment.argument_signature) -> a.semantic_type) p.arguments);
      Alcotest.(check (list (list string))) "observed types still inferred" [ [ "atom" ]; [ "atom" ] ]
        (List.map (fun (a : Query_environment.argument_signature) -> a.types) p.arguments);
      Alcotest.(check int) "examples" 2 (List.length p.examples));
  match Query_environment.find env "person" with
  | None -> Alcotest.fail "person missing"
  | Some p ->
      Alcotest.(check (option string)) "undeclared description" None p.description;
      Alcotest.(check bool) "undeclared roles" true
        (List.for_all (fun (a : Query_environment.argument_signature) -> a.role = None && a.semantic_type = None) p.arguments)

let test_environment_json () =
  let env = env_of (memory_store ~declaration:created_by_decl ()) in
  let json = Query_environment.to_json env in
  let open Yojson.Safe.Util in
  let preds = json |> member "predicates" |> to_list in
  let by_name n = List.find (fun p -> p |> member "name" |> to_string = n) preds in
  let created_by = by_name "created_by" and person = by_name "person" in
  Alcotest.(check string) "description" "Relates a work to the person who created it."
    (created_by |> member "description" |> to_string);
  let arg0 = created_by |> member "arguments" |> index 0 in
  Alcotest.(check string) "role" "Work" (arg0 |> member "role" |> to_string);
  Alcotest.(check string) "semanticType" "work" (arg0 |> member "semanticType" |> to_string);
  Alcotest.(check (list string)) "undeclared predicate keeps the old shape" [ "name"; "arity"; "count"; "arguments"; "examples" ]
    (keys person);
  Alcotest.(check (list string)) "undeclared argument keeps the old shape" [ "position"; "types" ]
    (person |> member "arguments" |> index 0 |> keys)

let legacy_fingerprint =
  let canonical = "created_by/2[0:atom,1:atom];person/1[0:atom]|" ^ Query_environment.language_version in
  "sha256:" ^ Digestif.SHA256.to_hex (Digestif.SHA256.digest_string canonical)

let test_fingerprint () =
  let plain = (env_of (memory_store ())).fingerprint in
  Alcotest.(check string) "undeclared fingerprint unchanged" legacy_fingerprint plain;
  let declared = (env_of (memory_store ~declaration:created_by_decl ())).fingerprint in
  Alcotest.(check bool) "declaration changes fingerprint" true (declared <> plain);
  Alcotest.(check string) "deterministic" declared (env_of (memory_store ~declaration:created_by_decl ())).fingerprint;
  let reworded =
    decl ~description:"Who made the work." [ ("Work", Some "work"); ("Creator", Some "person") ]
  in
  Alcotest.(check bool) "description changes fingerprint" true
    ((env_of (memory_store ~declaration:reworded ())).fingerprint <> declared);
  let fp d = (env_of (memory_store ~declaration:d ())).fingerprint in
  let layers =
    [
      fp (description_only "Who made the work.");
      fp (decl [ ("Work", None); ("Creator", None) ]);
      fp (decl ~description:"Who made the work." [ ("Work", None); ("Creator", None) ]);
      fp (decl [ ("Work", Some "work"); ("Creator", Some "person") ]);
      fp reworded;
    ]
  in
  Alcotest.(check int) "every metadata layer is distinct" (List.length layers)
    (List.length (List.sort_uniq String.compare (plain :: layers)) - 1)

let test_environment_description_only () =
  let env = env_of (memory_store ~declaration:(description_only "Relates a work to its creator.") ()) in
  match Query_environment.find env "created_by" with
  | None -> Alcotest.fail "created_by missing"
  | Some p ->
      Alcotest.(check (option string)) "description" (Some "Relates a work to its creator.") p.description;
      Alcotest.(check bool) "no roles or semantic types" true
        (List.for_all (fun (a : Query_environment.argument_signature) -> a.role = None && a.semantic_type = None) p.arguments);
      let open Yojson.Safe.Util in
      let json = Query_environment.predicate_to_json p in
      Alcotest.(check (list string)) "predicate keys" [ "name"; "arity"; "count"; "description"; "arguments"; "examples" ] (keys json);
      Alcotest.(check (list string)) "argument keys unchanged" [ "position"; "types" ]
        (json |> member "arguments" |> index 0 |> keys)

let test_mismatched_declaration_ignored () =
  let env = env_of (memory_store ~declaration:(decl [ ("Only", None) ]) ()) in
  match Query_environment.find env "created_by" with
  | Some p ->
      Alcotest.(check bool) "no roles" true (List.for_all (fun (a : Query_environment.argument_signature) -> a.role = None) p.arguments);
      Alcotest.(check string) "fingerprint as undeclared" legacy_fingerprint env.fingerprint
  | None -> Alcotest.fail "created_by missing"

(* --- native pack, controller and compile --- *)

let test_controller_detailed () =
  let dir = temp_dir "controller" in
  let json =
    run
      (let open Lwt.Syntax in
       let* store = Pack_backend.init ~fresh:true dir in
       let* () = Pack_backend.write_predicate_batch ~declaration:created_by_decl store "created_by" created_by_facts "c" in
       let* () = Pack_backend.write_predicate_batch store "person" person_facts "p" in
       Controller.list_predicates_detailed ~names:[ "created_by" ] store)
  in
  cleanup dir;
  match json with
  | Error e -> Alcotest.fail e
  | Ok json ->
      let open Yojson.Safe.Util in
      let p = json |> member "predicates" |> index 0 in
      Alcotest.(check string) "description" "Relates a work to the person who created it." (p |> member "description" |> to_string);
      Alcotest.(check (list string)) "roles" [ "Work"; "Creator" ]
        (p |> member "arguments" |> to_list |> List.map (fun a -> a |> member "role" |> to_string))

let source =
  String.concat "\n"
    [
      "% Work creation relationships";
      "%! created_by(Work:work, Creator:person)";
      "%  Relates a work to the person who created it.";
      "created_by(work1, alice).";
      "created_by(work2, bob).";
      "";
    ]

let compile_into git pack_dir =
  let open Lwt.Syntax in
  let* pack = Pack_backend.init ~fresh:true pack_dir in
  let* _ = Cli_compile.compile_predicate pack git "created_by" in
  let* _ = Cli_compile.compile_predicate pack git "person" in
  let* _ = Cli_compile.compile_predicate pack git "knows" in
  Lwt.return pack

let test_compile_from_git () =
  let git_dir = temp_dir "git" and pack_a = temp_dir "pack_a" and pack_b = temp_dir "pack_b" in
  let result =
    run
      (let open Lwt.Syntax in
       let* git = Git_backend.init git_dir in
       let* () = Git_backend.write_predicate git "created_by.pl" source in
       let* () = Git_backend.write_predicate git "person.pl" "% People\nperson(alice).\nperson(bob).\n" in
       let* () = Git_backend.write_predicate git "knows.pl" "%! knows\n% The first person knows the second.\nknows(alice, bob).\n" in
       let* a = compile_into git pack_a in
       let* b = compile_into git pack_b in
       let* meta_a = Pack_backend.Reader.find a (Pack_layout.meta_path "created_by") in
       let* meta_b = Pack_backend.Reader.find b (Pack_layout.meta_path "created_by") in
       let* person = Pack_backend.get_manifest a "person" in
       let* knows = Pack_backend.get_manifest a "knows" in
       let* manifest = Pack_backend.get_manifest a "created_by" in
       let* rows = Controller.run_query ~max_results:100 ~language:"dsl" a "find W\nwhere\n  created_by(W, alice)" ~offset:None ~limit:None in
       Lwt.return (meta_a, meta_b, person, knows, manifest, rows))
  in
  List.iter cleanup [ git_dir; pack_a; pack_b ];
  let meta_a, meta_b, person, knows, manifest, rows = result in
  (match knows with
  | Some { declaration = Some d; _ } ->
      Alcotest.(check bool) "description-only compiled" true (d = description_only "The first person knows the second.")
  | _ -> Alcotest.fail "expected a description-only declaration");
  Alcotest.(check (option string)) "compile is deterministic" meta_a meta_b;
  (match manifest with
  | Some { declaration = Some d; arity; fact_count; _ } ->
      Alcotest.(check int) "arity" 2 arity;
      Alcotest.(check int) "fact count" 2 fact_count;
      Alcotest.(check bool) "declaration compiled" true (d = created_by_decl)
  | _ -> Alcotest.fail "expected a declared manifest");
  (match person with
  | Some { declaration = None; _ } -> ()
  | _ -> Alcotest.fail "plain comments must not produce a declaration");
  match rows with
  | Controller.Success json ->
      let open Yojson.Safe.Util in
      Alcotest.(check int) "query unaffected" 1 (json |> member "count" |> to_int)
  | _ -> Alcotest.fail "query failed"

let () =
  Alcotest.run "BeingDB predicate declarations"
    [
      ( "Parsing",
        [
          Alcotest.test_case "progressive forms" `Quick test_progressive_forms;
          Alcotest.test_case "description only at any arity" `Quick test_description_only_any_arity;
          Alcotest.test_case "full declaration" `Quick test_extract_full;
          Alcotest.test_case "minimal declaration" `Quick test_extract_minimal;
          Alcotest.test_case "plain comments" `Quick test_plain_comments_are_not_declarations;
          Alcotest.test_case "invalid declarations warn" `Quick test_invalid_declarations_warn;
          Alcotest.test_case "select" `Quick test_select;
        ] );
      ( "Encoding",
        [
          Alcotest.test_case "declaration JSON" `Quick test_declaration_json_roundtrip;
          Alcotest.test_case "manifest compatibility" `Quick test_manifest_compatibility;
        ] );
      ( "Environment",
        [
          Alcotest.test_case "fields" `Quick test_environment_fields;
          Alcotest.test_case "JSON" `Quick test_environment_json;
          Alcotest.test_case "fingerprint" `Quick test_fingerprint;
          Alcotest.test_case "description only" `Quick test_environment_description_only;
          Alcotest.test_case "mismatched declaration ignored" `Quick test_mismatched_declaration_ignored;
        ] );
      ( "Pack",
        [
          Alcotest.test_case "controller detailed JSON" `Quick test_controller_detailed;
          Alcotest.test_case "compile from Git" `Quick test_compile_from_git;
        ] );
    ]
