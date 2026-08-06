(** HTTP API tests for BeingDB *)

open Beingdb

(** Helper: Create test Pack store *)
let create_test_pack name =
  let test_dir = Filename.concat (Filename.get_temp_dir_name ()) 
                   (Printf.sprintf "beingdb_api_test_%s_%d" name (Unix.getpid ())) in
  
  (* Remove if exists, then create *)
  (try Unix.rmdir test_dir with _ -> ());
  Unix.mkdir test_dir 0o755;
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* store = Pack_backend.init ~fresh:true test_dir in
    
    (* Add some test data *)
    let by_predicate =
      [
        ( "created",
          [
            Fact.make "created" [ Value.Atom "tina_keane"; Value.Atom "she" ];
            Fact.make "created" [ Value.Atom "lynn_hershman"; Value.Atom "lorna" ];
          ] );
        ( "shown_in",
          [
            Fact.make "shown_in" [ Value.Atom "she"; Value.Atom "rewind_1995" ];
            Fact.make "shown_in" [ Value.Atom "lorna"; Value.Atom "rewind_1995" ];
          ] );
        ("artist", [ Fact.make "artist" [ Value.Atom "tina_keane" ]; Fact.make "artist" [ Value.Atom "lynn_hershman" ] ]);
      ]
    in
    
    let* () = Lwt_list.iter_s (fun (pred, facts) ->
      Pack_backend.write_predicate_batch store pred facts (Printf.sprintf "compile %s" pred)
    ) by_predicate in
    Lwt.return (store, test_dir)
  )

(** Helper: Create Dream test app *)
let create_app pack max_results =
  let router = Dream.router [
    Dream.get "/" (fun _req -> Dream.respond "OK");
    Dream.get "/version" (fun _req -> 
      Dream.json {|{"version":"0.1.0","name":"BeingDB"}|});
    Dream.get "/predicates" (Beingdb.Api.handle_list_predicates pack);
    Dream.get "/query/:predicate" (fun req ->
      let predicate = Dream.param req "predicate" in
      Beingdb.Api.handle_query max_results pack predicate req);
    Dream.post "/query" (Beingdb.Api.handle_query_language max_results pack);
  ] in
  router

(** Test: GET / health check *)
let test_health_check () =
  let (pack, test_dir) = create_test_pack "health" in
  let app = create_app pack 1000 in
  
  let response = Dream.test app (Dream.request ~target:"/" "") in
  let status = Dream.status response in
  
  Alcotest.(check int) "status 200" 200 (Dream.status_to_int status);
  
  (* Cleanup *)
  let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
  let _ = Unix.system cmd in
  ()

(** Test: GET /version *)
let test_version_endpoint () =
  let (pack, test_dir) = create_test_pack "version" in
  let app = create_app pack 1000 in
  
  let response = Dream.test app (Dream.request ~target:"/version" "") in
  Lwt_main.run (
    let open Lwt.Syntax in
    let* body = Dream.body response in
    let json = Yojson.Safe.from_string body in
    
    let version = Yojson.Safe.Util.member "version" json 
                  |> Yojson.Safe.Util.to_string in
    let name = Yojson.Safe.Util.member "name" json 
               |> Yojson.Safe.Util.to_string in
    
    Alcotest.(check string) "name is BeingDB" "BeingDB" name;
    Alcotest.(check bool) "version exists" true (String.length version > 0);
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  )

(** Test: GET /predicates without samples *)
let test_list_predicates () =
  let (pack, test_dir) = create_test_pack "list_predicates" in
  let app = create_app pack 1000 in
  
  let response = Dream.test app (Dream.request ~target:"/predicates" "") in
  Lwt_main.run (
    let open Lwt.Syntax in
    let* body = Dream.body response in
    let json = Yojson.Safe.from_string body in
    
    let predicates = Yojson.Safe.Util.member "predicates" json 
                     |> Yojson.Safe.Util.to_list in
    
    Alcotest.(check bool) "has predicates" true (List.length predicates > 0);
    
    (* Check structure of first predicate *)
    let pred = List.hd predicates in
    let name = Yojson.Safe.Util.member "name" pred |> Yojson.Safe.Util.to_string in
    let arity = Yojson.Safe.Util.member "arity" pred |> Yojson.Safe.Util.to_int in
    
    Alcotest.(check bool) "name is string" true (String.length name > 0);
    Alcotest.(check bool) "arity is positive" true (arity > 0);
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  )

(** Test: GET /predicates?samples=5 *)
let test_list_predicates_with_samples () =
  let (pack, test_dir) = create_test_pack "list_samples" in
  let app = create_app pack 1000 in
  
  let response = Dream.test app (Dream.request ~target:"/predicates?samples=5" "") in
  Lwt_main.run (
    let open Lwt.Syntax in
    let* body = Dream.body response in
    let json = Yojson.Safe.from_string body in
    
    let predicates = Yojson.Safe.Util.member "predicates" json 
                     |> Yojson.Safe.Util.to_list in
    
    (* Check at least one predicate has samples *)
    let has_samples = List.exists (fun pred ->
      match Yojson.Safe.Util.member "samples" pred with
      | `Null -> false
      | _ -> true
    ) predicates in
    
    Alcotest.(check bool) "at least one predicate has samples" true has_samples;
    
    (* Check samples_per_predicate field *)
    let samples_per_pred = Yojson.Safe.Util.member "samples_per_predicate" json
                           |> Yojson.Safe.Util.to_int in
    Alcotest.(check int) "samples_per_predicate is 5" 5 samples_per_pred;
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  )

(** Test: GET /query/:predicate *)
let test_query_single_predicate () =
  let (pack, test_dir) = create_test_pack "query_single" in
  let app = create_app pack 1000 in
  
  let response = Dream.test app (Dream.request ~target:"/query/created" "") in
  Lwt_main.run (
    let open Lwt.Syntax in
    let* body = Dream.body response in
    let json = Yojson.Safe.from_string body in
    
    let predicate = Yojson.Safe.Util.member "predicate" json 
                    |> Yojson.Safe.Util.to_string in
    let facts = Yojson.Safe.Util.member "facts" json 
                |> Yojson.Safe.Util.to_list in
    let count = Yojson.Safe.Util.member "count" json 
                |> Yojson.Safe.Util.to_int in
    
    Alcotest.(check string) "predicate name" "created" predicate;
    Alcotest.(check int) "fact count matches" (List.length facts) count;
    Alcotest.(check bool) "has facts" true (count > 0);
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  )

(** Test: GET /query/:predicate with invalid name *)
let test_query_invalid_predicate_name () =
  let (pack, test_dir) = create_test_pack "query_invalid" in
  let app = create_app pack 1000 in
  
  (* Try predicate with invalid characters *)
  let response = Dream.test app (Dream.request ~target:"/query/invalid$name" "") in
  let status = Dream.status response in
  
  Alcotest.(check int) "status 400 for invalid name" 400 (Dream.status_to_int status);
  
  (* Cleanup *)
  let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
  let _ = Unix.system cmd in
  ()

(** Test: POST /query with simple pattern *)
let test_post_query_simple () =
  let (pack, test_dir) = create_test_pack "post_simple" in
  let app = create_app pack 1000 in
  
  let body = {|{"query":"created(Artist, Work)"}|} in
  let request = Dream.request ~target:"/query" ~method_:`POST body in
  let response = Dream.test app request in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* resp_body = Dream.body response in
    let json = Yojson.Safe.from_string resp_body in
    
    let results = Yojson.Safe.Util.member "results" json 
                  |> Yojson.Safe.Util.to_list in
    
    Alcotest.(check bool) "has results" true (List.length results > 0);
    
    (* Check variables *)
    let vars = Yojson.Safe.Util.member "variables" json 
               |> Yojson.Safe.Util.to_list 
               |> List.map Yojson.Safe.Util.to_string in
    
    Alcotest.(check bool) "has Artist var" true (List.mem "Artist" vars);
    Alcotest.(check bool) "has Work var" true (List.mem "Work" vars);
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  )

(** Test: POST /query with join *)
let test_post_query_join () =
  let (pack, test_dir) = create_test_pack "post_join" in
  let app = create_app pack 1000 in
  
  let body = {|{"query":"created(Artist, Work), shown_in(Work, Event)"}|} in
  let request = Dream.request ~target:"/query" ~method_:`POST body in
  let response = Dream.test app request in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* resp_body = Dream.body response in
    let json = Yojson.Safe.from_string resp_body in
    
    let results = Yojson.Safe.Util.member "results" json 
                  |> Yojson.Safe.Util.to_list in
    
    (* Join should have results (we have matching data) *)
    Alcotest.(check bool) "join has results" true (List.length results > 0);
    
    (* Check variables *)
    let vars = Yojson.Safe.Util.member "variables" json 
               |> Yojson.Safe.Util.to_list 
               |> List.map Yojson.Safe.Util.to_string in
    
    Alcotest.(check bool) "has Artist var" true (List.mem "Artist" vars);
    Alcotest.(check bool) "has Work var" true (List.mem "Work" vars);
    Alcotest.(check bool) "has Event var" true (List.mem "Event" vars);
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  )

(** Test: POST /query with offset and limit *)
let test_post_query_pagination () =
  let (pack, test_dir) = create_test_pack "post_pagination" in
  let app = create_app pack 1000 in
  
  let body = {|{"query":"created(Artist, Work)", "offset":0, "limit":1}|} in
  let request = Dream.request ~target:"/query" ~method_:`POST body in
  let response = Dream.test app request in
  
  Lwt_main.run (
    let open Lwt.Syntax in
    let* resp_body = Dream.body response in
    let json = Yojson.Safe.from_string resp_body in
    
    let results = Yojson.Safe.Util.member "results" json 
                  |> Yojson.Safe.Util.to_list in
    
    (* With limit=1, should get at most 1 result *)
    Alcotest.(check bool) "respects limit" true (List.length results <= 1);
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  )

(** Test: POST /query with invalid JSON *)
let test_post_query_invalid_json () =
  let (pack, test_dir) = create_test_pack "post_invalid_json" in
  let app = create_app pack 1000 in
  
  let body = {|{not valid json}|} in
  let request = Dream.request ~target:"/query" ~method_:`POST body in
  let response = Dream.test app request in
  let status = Dream.status response in
  
  Alcotest.(check int) "status 400 for invalid JSON" 400 (Dream.status_to_int status);
  
  (* Cleanup *)
  let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
  let _ = Unix.system cmd in
  ()

(** Test: POST /query with missing query field *)
let test_post_query_missing_field () =
  let (pack, test_dir) = create_test_pack "post_missing_field" in
  let app = create_app pack 1000 in
  
  let body = {|{"offset":0}|} in
  let request = Dream.request ~target:"/query" ~method_:`POST body in
  let response = Dream.test app request in
  let status = Dream.status response in
  
  Alcotest.(check int) "status 400 for missing query" 400 (Dream.status_to_int status);
  
  (* Cleanup *)
  let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
  let _ = Unix.system cmd in
  ()

(** Test: POST /query with invalid syntax *)
let test_post_query_invalid_syntax () =
  let (pack, test_dir) = create_test_pack "post_invalid_syntax" in
  let app = create_app pack 1000 in
  
  let body = {|{"query":"this is not valid query syntax"}|} in
  let request = Dream.request ~target:"/query" ~method_:`POST body in
  let response = Dream.test app request in
  let status = Dream.status response in
  
  Alcotest.(check int) "status 400 for invalid syntax" 400 (Dream.status_to_int status);
  
  (* Cleanup *)
  let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
  let _ = Unix.system cmd in
  ()

(** Test: POST /query with negative offset *)
let test_post_query_negative_offset () =
  let (pack, test_dir) = create_test_pack "post_negative_offset" in
  let app = create_app pack 1000 in
  
  let body = {|{"query":"created(A, W)", "offset":-5, "limit":10}|} in
  let request = Dream.request ~target:"/query" ~method_:`POST body in
  let response = Dream.test app request in
  let status = Dream.status response in
  
  Alcotest.(check int) "status 400 for negative offset" 400 (Dream.status_to_int status);
  
  (* Cleanup *)
  let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
  let _ = Unix.system cmd in
  ()

(** Test: POST /query with cartesian product (duplicate predicates) *)
let test_post_query_cartesian_product () =
  let (pack, test_dir) = create_test_pack "post_cartesian" in
  let app = create_app pack 1000 in
  
  let body = {|{"query":"artist(A1), artist(A2)"}|} in
  let request = Dream.request ~target:"/query" ~method_:`POST body in
  let response = Dream.test app request in
  let status = Dream.status response in
  
  Alcotest.(check int) "status 400 for cartesian product" 400 (Dream.status_to_int status);
  
  (* Cleanup *)
  let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
  let _ = Unix.system cmd in
  ()

(** Test: Result limiting enforcement *)
let test_result_limit_enforcement () =
  let (pack, test_dir) = create_test_pack "result_limit" in
  let max_results = 1 in  (* Set very low limit *)
  let app = create_app pack max_results in
  
  let response = Dream.test app (Dream.request ~target:"/query/created" "") in
  Lwt_main.run (
    let open Lwt.Syntax in
    let* body = Dream.body response in
    let json = Yojson.Safe.from_string body in
    
    let count = Yojson.Safe.Util.member "count" json 
                |> Yojson.Safe.Util.to_int in
    let limited = Yojson.Safe.Util.member "limited" json 
                  |> Yojson.Safe.Util.to_bool in
    let max_res = Yojson.Safe.Util.member "max_results" json 
                  |> Yojson.Safe.Util.to_int in
    
    Alcotest.(check bool) "result is limited" true limited;
    Alcotest.(check bool) "respects max_results" true (count <= max_results);
    Alcotest.(check int) "max_results matches" max_results max_res;
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  )

(** Test: 404 for missing predicate *)
let test_query_missing_predicate () =
  let (pack, test_dir) = create_test_pack "missing_pred" in
  let app = create_app pack 1000 in
  
  let response = Dream.test app (Dream.request ~target:"/query/nonexistent" "") in
  Lwt_main.run (
    let open Lwt.Syntax in
    let* body = Dream.body response in
    let json = Yojson.Safe.from_string body in
    
    (* Should return empty results, not 404 (this is a design choice) *)
    let facts = Yojson.Safe.Util.member "facts" json 
                |> Yojson.Safe.Util.to_list in
    let count = Yojson.Safe.Util.member "count" json 
                |> Yojson.Safe.Util.to_int in
    
    Alcotest.(check int) "empty results for missing predicate" 0 count;
    Alcotest.(check int) "zero facts" 0 (List.length facts);
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    Lwt.return ()
  )

(** Test: POST /query with language=dsl, action=execute *)
let test_post_query_dsl_execute () =
  let pack, test_dir = create_test_pack "post_dsl_execute" in
  let app = create_app pack 1000 in
  let body = {|{"query":"find Artist\nwhere\n  artist(Artist)\n","language":"dsl"}|} in
  let request = Dream.request ~target:"/query" ~method_:`POST body in
  let response = Dream.test app request in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* resp_body = Dream.body response in
     let json = Yojson.Safe.from_string resp_body in
     let results = Yojson.Safe.Util.(json |> member "results" |> to_list) in
     Alcotest.(check int) "2 artists" 2 (List.length results);
     let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
     let _ = Unix.system cmd in
     Lwt.return ())

(** Test: POST /query with language=dsl, action=validate, unknown predicate *)
let test_post_query_dsl_validate_invalid () =
  let pack, test_dir = create_test_pack "post_dsl_validate" in
  let app = create_app pack 1000 in
  let body = {|{"query":"find X\nwhere\n  artst(X)\n","language":"dsl","action":"validate"}|} in
  let request = Dream.request ~target:"/query" ~method_:`POST body in
  let response = Dream.test app request in
  Alcotest.(check int) "status 400" 400 (Dream.status_to_int (Dream.status response));
  Lwt_main.run
    (let open Lwt.Syntax in
     let* resp_body = Dream.body response in
     let json = Yojson.Safe.from_string resp_body in
     Alcotest.(check bool) "valid false" false Yojson.Safe.Util.(json |> member "valid" |> to_bool);
     let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
     let _ = Unix.system cmd in
     Lwt.return ())

(** Test: GET /predicates?detailed=true includes schema + fingerprint *)
let test_list_predicates_detailed () =
  let pack, test_dir = create_test_pack "predicates_detailed" in
  let app = create_app pack 1000 in
  let response = Dream.test app (Dream.request ~target:"/predicates?detailed=true" "") in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* body = Dream.body response in
     let json = Yojson.Safe.from_string body in
     let open Yojson.Safe.Util in
     let fingerprint = json |> member "environmentFingerprint" |> to_string in
     Alcotest.(check bool) "fingerprint is sha256-tagged" true (String.length fingerprint > 7 && String.sub fingerprint 0 7 = "sha256:");
     let predicates = json |> member "predicates" |> to_list in
     let created = List.find (fun p -> p |> member "name" |> to_string = "created") predicates in
     let arguments = created |> member "arguments" |> to_list in
     Alcotest.(check int) "created has 2 argument positions" 2 (List.length arguments);
     let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
     let _ = Unix.system cmd in
     Lwt.return ())

let () =
  Alcotest.run "BeingDB API" [
    "Basic Endpoints", [
      Alcotest.test_case "GET /" `Quick test_health_check;
      Alcotest.test_case "GET /version" `Quick test_version_endpoint;
    ];
    "List Predicates", [
      Alcotest.test_case "GET /predicates" `Quick test_list_predicates;
      Alcotest.test_case "GET /predicates?samples=5" `Quick test_list_predicates_with_samples;
      Alcotest.test_case "GET /predicates?detailed=true" `Quick test_list_predicates_detailed;
    ];
    "Single Predicate Query", [
      Alcotest.test_case "GET /query/:predicate" `Quick test_query_single_predicate;
      Alcotest.test_case "invalid predicate name" `Quick test_query_invalid_predicate_name;
      Alcotest.test_case "missing predicate" `Quick test_query_missing_predicate;
    ];
    "Complex Queries", [
      Alcotest.test_case "POST /query simple" `Quick test_post_query_simple;
      Alcotest.test_case "POST /query join" `Quick test_post_query_join;
      Alcotest.test_case "POST /query pagination" `Quick test_post_query_pagination;
    ];
    "Expressive Query Language", [
      Alcotest.test_case "POST /query language=dsl execute" `Quick test_post_query_dsl_execute;
      Alcotest.test_case "POST /query language=dsl validate invalid" `Quick test_post_query_dsl_validate_invalid;
    ];
    "Error Handling", [
      Alcotest.test_case "invalid JSON" `Quick test_post_query_invalid_json;
      Alcotest.test_case "missing query field" `Quick test_post_query_missing_field;
      Alcotest.test_case "invalid query syntax" `Quick test_post_query_invalid_syntax;
      Alcotest.test_case "negative offset" `Quick test_post_query_negative_offset;
      Alcotest.test_case "cartesian product" `Quick test_post_query_cartesian_product;
    ];
    "Result Limiting", [
      Alcotest.test_case "max_results enforcement" `Quick test_result_limit_enforcement;
    ];
  ]
