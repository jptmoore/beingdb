(** CLI: `export` -- write a compiled Pack store as a single JSON file that
    the BeingDB WebAssembly runtime (beingdb-wasm) loads in a web browser.
    Shared by the standalone [beingdb-export] binary and the
    [beingdb export] subcommand.

    The file is the pack's logical key/value tree ([facts/], [index/],
    [meta/]) read through {!Pack_backend.Reader}, the same reader the native
    query engine uses: an object is a directory (children in [Reader.list]
    order) and a string is the contents at that path. Nothing is recompiled
    or reinterpreted, and the output is deterministic. *)

open Lwt.Syntax
open Cmdliner

let format = "beingdb-logical-pack-view"
let format_version = 0

let rec walk store path : Yojson.Safe.t Lwt.t =
  let* contents = Pack_backend.Reader.find store path in
  match contents with
  | Some s -> Lwt.return (`String s)
  | None ->
      let* children = Pack_backend.Reader.list store path in
      let+ kvs =
        Lwt_list.map_s
          (fun step ->
            let+ v = walk store (path @ [ step ]) in
            (step, v))
          children
      in
      `Assoc kvs

let export store =
  let+ tree = walk store [] in
  `Assoc [ ("format", `String format); ("formatVersion", `Int format_version); ("tree", tree) ]

let count_children json name =
  match json with
  | `Assoc top -> (
      match List.assoc_opt "tree" top with
      | Some (`Assoc tree) -> ( match List.assoc_opt name tree with Some (`Assoc kvs) -> List.length kvs | _ -> 0)
      | _ -> 0)
  | _ -> 0

let run pack_path output =
  if not (Sys.file_exists (Filename.concat pack_path "store.control")) then (
    Printf.eprintf "export: [ERROR] Not a compiled BeingDB pack (no store.control): %s\n%!" pack_path;
    exit 1);
  Lwt_main.run
    (let* store = Pack_backend.init ~readonly:true pack_path in
     let* json =
       Lwt.finalize (fun () -> export store) (fun () -> Pack_backend.close_repo (Pack_backend.Store.repo store))
     in
     Yojson.Safe.to_file output json;
     Lwt_io.printlf "Exported %s -> %s (%d predicates, %d facts, %d bytes)" pack_path output (count_children json "meta")
       (count_children json "facts") (Unix.stat output).Unix.st_size)

let pack_arg =
  let doc = "Compiled Pack store directory to export" in
  Arg.(value & opt string "./pack_store" & info [ "pack"; "p" ] ~docv:"DIR" ~doc)

let output_arg =
  let doc = "JSON file to write, for example ./facts.browser.json" in
  Arg.(required & opt (some string) None & info [ "output"; "o" ] ~docv:"FILE" ~doc)

let cmd =
  let doc = "Export a compiled Pack store for querying in a web browser (beingdb-wasm)" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Writes the compiled Pack store as one JSON file that the BeingDB WebAssembly runtime loads in a browser, so \
         the facts can be published as a static website and queried without a server.";
      `P "Publish the file with beingdb-wasm: https://github.com/jptmoore/beingdb-wasm";
      `P "Example:";
      `Pre "  beingdb export --pack ./pack_store -o ./facts.browser.json";
      `Pre "  beingdb-export --pack ./pack_store -o ./facts.browser.json";
    ]
  in
  let info = Cmd.info "export" ~version:Version.version ~doc ~man in
  Cmd.v info Term.(const run $ pack_arg $ output_arg)
