(** Unit tests for BeingDB *)

open Lwt.Infix

let test_parse_fact () =
  let open Beingdb.Parse_predicate in
  
  (* Test simple fact *)
  let fact1 = "created(tina_keane, she)." in
  let result1 = parse_fact fact1 in
  Alcotest.(check (option (pair string (list string))))
    "parse simple fact" 
    (Some ("created", ["tina_keane"; "she"]))
    result1;
  
  (* Test fact without trailing dot *)
  let fact2 = "shown_in(she, rewind_exhibition_1995)" in
  let result2 = parse_fact fact2 in
  Alcotest.(check (option (pair string (list string))))
    "parse fact without dot"
    (Some ("shown_in", ["she"; "rewind_exhibition_1995"]))
    result2;
  
  (* Test fact with spaces *)
  let fact3 = "created( tina_keane , she )." in
  let result3 = parse_fact fact3 in
  Alcotest.(check (option (pair string (list string))))
    "parse fact with spaces"
    (Some ("created", ["tina_keane"; "she"]))
    result3;
  
  (* Test invalid fact *)
  let fact4 = "not_a_fact" in
  let result4 = parse_fact fact4 in
  Alcotest.(check (option (pair string (list string))))
    "parse invalid fact"
    None
    result4

let test_git_backend () =
  Lwt_main.run begin
    let test_dir = Filename.temp_file "beingdb_test_git_" "" in
    Unix.unlink test_dir;
    Unix.mkdir test_dir 0o755;
    
    Beingdb.Git_backend.init test_dir
    >>= fun store ->
    
    (* Write some facts *)
    let facts = [
      "created(artist_a, work_1).";
      "created(artist_b, work_2).";
    ] in
    let content = String.concat "\n" facts in
    Beingdb.Git_backend.write_predicate store "created" content
    >>= fun () ->
    
    (* Read them back *)
    Beingdb.Git_backend.read_predicate store "created"
    >>= fun read_content ->
    
    let read_facts = match read_content with
      | Some content -> String.split_on_char '\n' content |> List.filter (fun s -> String.trim s <> "")
      | None -> []
    in
    
    Alcotest.(check (list string))
      "git backend read/write"
      facts
      read_facts;
    
    (* List predicates *)
    Beingdb.Git_backend.list_predicates store
    >>= fun predicates ->
    
    Alcotest.(check (list string))
      "git backend list predicates"
      ["created"]
      predicates;
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    
    Lwt.return ()
  end

let test_pack_backend () =
  Lwt_main.run begin
    let test_dir = Filename.temp_file "beingdb_test_pack_" "" in
    Unix.unlink test_dir;
    Unix.mkdir test_dir 0o755;
    
    Beingdb.Pack_backend.init test_dir
    >>= fun store ->
    
    (* Write some facts *)
    Beingdb.Pack_backend.write_fact store "created" ["artist_a"; "work_1"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" ["artist_b"; "work_2"]
    >>= fun () ->
    Beingdb.Pack_backend.write_fact store "created" ["artist_a"; "work_3"]
    >>= fun () ->
    
    (* Query all facts *)
    Beingdb.Pack_backend.query_all store "created"
    >>= fun all_facts ->
    
    Alcotest.(check int)
      "pack backend stores 3 facts"
      3
      (List.length all_facts);
    
    (* Query with pattern - all works by artist_a *)
    Beingdb.Pack_backend.query_predicate store "created" ["artist_a"; "_"]
    >>= fun filtered_facts ->
    
    Alcotest.(check int)
      "pack backend pattern match finds 2 facts"
      2
      (List.length filtered_facts);
    
    (* List predicates *)
    Beingdb.Pack_backend.list_predicates store
    >>= fun predicates ->
    
    Alcotest.(check (list string))
      "pack backend list predicates"
      ["created"]
      predicates;
    
    (* Cleanup *)
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote test_dir) in
    let _ = Unix.system cmd in
    
    Lwt.return ()
  end

(* Test suite *)
let () =
  Alcotest.run "BeingDB" [
    "Sync", [
      Alcotest.test_case "parse_fact" `Quick test_parse_fact;
    ];
    "Git Backend", [
      Alcotest.test_case "read/write" `Quick test_git_backend;
    ];
    "Pack Backend", [
      Alcotest.test_case "query" `Quick test_pack_backend;
    ];
  ]
