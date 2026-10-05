(** See {!Memory_store} (mli). *)

type node = { mutable contents : string option; children : (string, node) Hashtbl.t }

let new_node () = { contents = None; children = Hashtbl.create 8 }

let rec lookup node = function
  | [] -> Some node
  | step :: rest -> ( match Hashtbl.find_opt node.children step with Some child -> lookup child rest | None -> None)

let rec add node path value =
  match path with
  | [] -> node.contents <- Some value
  | step :: rest ->
      let child =
        match Hashtbl.find_opt node.children step with
        | Some child -> child
        | None ->
            let child = new_node () in
            Hashtbl.replace node.children step child;
            child
      in
      add child rest value

module Reader = struct
  type t = node

  let find t path = Lwt.return (Option.bind (lookup t path) (fun n -> n.contents))

  let list t path =
    match lookup t path with
    | None -> Lwt.return []
    | Some n -> Lwt.return (List.sort String.compare (Hashtbl.fold (fun k _ acc -> k :: acc) n.children []))
end

include Pack_layout.Make (Reader)

let create = new_node
let add_predicate ?declaration t predicate facts =
  List.iter (fun (path, value) -> add t path value) (Pack_layout.predicate_entries ?declaration predicate facts)

let of_facts facts =
  let t = create () in
  let order = ref [] in
  let groups = Hashtbl.create 16 in
  List.iter
    (fun (f : Fact.t) ->
      match Hashtbl.find_opt groups f.predicate with
      | Some fs -> Hashtbl.replace groups f.predicate (f :: fs)
      | None ->
          order := f.predicate :: !order;
          Hashtbl.replace groups f.predicate [ f ])
    facts;
  List.iter (fun p -> add_predicate t p (List.rev (Hashtbl.find groups p))) (List.rev !order);
  t
