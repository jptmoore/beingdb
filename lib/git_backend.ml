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
  (* Try with .pl extension first, then without *)
  let key_with_ext = [ "predicates"; name ^ ".pl" ] in
  let key_without_ext = [ "predicates"; name ] in
  let* result = Store.find store key_with_ext in
  match result with
  | Some _ -> Lwt.return result
  | None -> Store.find store key_without_ext

let write_predicate store name content =
  let key = [ "predicates"; name ] in
  Store.set_exn store key content ~info:(info (Printf.sprintf "Update %s" name))

let list_predicates store =
  let prefix = [ "predicates" ] in
  let* entries = Store.list store prefix in
  entries
  |> List.map (fun (step, _tree) -> 
      let name = Irmin.Type.to_string Store.Path.step_t step in
      (* Strip .pl extension if present *)
      if String.ends_with ~suffix:".pl" name then
        String.sub name 0 (String.length name - 3)
      else
        name)
  |> Lwt.return
