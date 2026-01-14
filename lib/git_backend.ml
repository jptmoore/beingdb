(** Git Backend: Human-editable source of truth for predicates *)

open Lwt.Syntax

module Store = Irmin_git_unix.FS.KV(Irmin.Contents.String)
module Store_info = Irmin_unix.Info(Store.Info)

let info message = Store_info.v ~author:"beingdb" "%s" message

type t = Store.t

let init path =
  let config = Irmin_git.config ~bare:true path in
  let* repo = Store.Repo.v config in
  Store.main repo

let read_predicate store name =
  let key = [ "predicates"; name ] in
  Store.find store key

let write_predicate store name content =
  let key = [ "predicates"; name ] in
  Store.set_exn store key content ~info:(info (Printf.sprintf "Update %s" name))

let list_predicates store =
  let prefix = [ "predicates" ] in
  let* entries = Store.list store prefix in
  entries
  |> List.map (fun (step, _tree) -> 
      Irmin.Type.to_string Store.Path.step_t step)
  |> Lwt.return
