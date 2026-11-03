(** `beingdb export`: the browser export is the pack's logical tree, read
    back through the same reader the query engine uses. *)

open Lwt.Syntax
open Beingdb

let with_pack f =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) (Printf.sprintf "beingdb_export_test_%d_%d" (Unix.getpid ()) (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Unix.system (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Lwt_main.run
        (let* store = Pack_backend.init ~fresh:true dir in
         let facts = [ Fact.make "created" [ Value.Atom "alice"; Value.Atom "work_1" ]; Fact.make "created" [ Value.Atom "bob"; Value.Atom "work_2" ] ] in
         let* () = Pack_backend.write_predicate_batch store "created" facts "compile created" in
         f store))

let member k = function `Assoc kvs -> List.assoc k kvs | _ -> Alcotest.fail ("not an object at " ^ k)
let keys = function `Assoc kvs -> List.map fst kvs | _ -> []

let test_export_tree () =
  with_pack (fun store ->
      let* json = Cli_export.export store in
      Alcotest.(check string) "format" "beingdb-logical-pack-view" (Yojson.Safe.Util.to_string (member "format" json));
      Alcotest.(check int) "formatVersion" 0 (Yojson.Safe.Util.to_int (member "formatVersion" json));
      let tree = member "tree" json in
      Alcotest.(check int) "facts" 2 (List.length (keys (member "facts" tree)));
      Alcotest.(check (list string)) "meta" [ "created" ] (keys (member "meta" tree));
      (* Every leaf is the contents the native reader returns at that path. *)
      let rec check path = function
        | `String s ->
            let+ found = Pack_backend.Reader.find store path in
            Alcotest.(check (option string)) (String.concat "/" path) (Some s) found
        | `Assoc kvs ->
            let* children = Pack_backend.Reader.list store path in
            Alcotest.(check (list string)) (String.concat "/" path ^ " children") children (List.map fst kvs);
            Lwt_list.iter_s (fun (k, v) -> check (path @ [ k ]) v) kvs
        | _ -> Alcotest.fail "unexpected node"
      in
      let* () = check [] tree in
      let* again = Cli_export.export store in
      Alcotest.(check string) "deterministic" (Yojson.Safe.to_string json) (Yojson.Safe.to_string again);
      Lwt.return_unit)

let () = Alcotest.run "export" [ ("export", [ Alcotest.test_case "logical tree" `Quick test_export_tree ]) ]
