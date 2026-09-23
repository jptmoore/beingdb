(** Pack_backend: the native compiled-pack adapter.

    Stores BeingDB's logical pack layout (see {!Pack_layout}) in an
    [Irmin_pack_unix] repository on the local filesystem. Everything
    Unix/Irmin-specific lives here: the Irmin Pack configuration, opening
    and closing the repository, and the writer used by
    [beingdb-compile]. Reading and interpreting the layout is delegated
    to the portable {!Pack_layout.Make}, so the query runtime only sees
    {!Runtime_store.S}. *)

open Lwt.Syntax

module Conf = struct
  let entries = 32
  let stable_hash = 256
  let contents_length_header = Some `Varint
  let inode_child_order = `Seeded_hash
  let forbid_empty_dir_persistence = false
end

module StoreMaker = Irmin_pack_unix.KV (Conf)
module Store = StoreMaker.Make (Irmin.Contents.String)
module Store_info = Irmin_unix.Info (Store.Info)

let info message = Store_info.v ~author:"beingdb" "%s" message

type repo = Store.Repo.t

let pack_config ?(fresh = false) ?(readonly = false) path =
  Irmin_pack.config path ~fresh ~readonly ~indexing_strategy:Irmin_pack.Indexing_strategy.minimal

let create ~fname =
  Lwt_main.run
    (let config = pack_config fname in
     let* repo = Store.Repo.v config in
     Store.main repo)

let init ?(fresh = false) ?(readonly = false) path =
  let config = pack_config ~fresh ~readonly path in
  let* repo = Store.Repo.v config in
  Store.main repo

let close_repo repo = Store.Repo.close repo

let step_to_string step = Irmin.Type.to_string Store.Path.step_t step

module Reader = struct
  type t = Store.t

  let find = Store.find

  let list store path =
    let* entries = Store.list store path in
    Lwt.return (List.map (fun (step, _tree) -> step_to_string step) entries)
end

include Pack_layout.Make (Reader)

(* --- writing (build-time only; not part of the runtime boundary) --- *)

let write_predicate_batch store predicate facts message =
  Store.with_tree_exn store [] ~info:(info message) (fun tree_opt ->
      let tree = Option.value tree_opt ~default:(Store.Tree.empty ()) in
      let* tree =
        Lwt_list.fold_left_s
          (fun tree (path, contents) -> Store.Tree.add tree path contents)
          tree
          (Pack_layout.predicate_entries predicate facts)
      in
      Lwt.return_some tree)

let clear store = Store.remove_exn store [] ~info:(info "Clear all facts")
