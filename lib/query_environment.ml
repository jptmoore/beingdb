(** See {!Query_environment} (mli) for documentation. *)

open Lwt.Syntax

type argument_signature = { position : int; types : string list }

type predicate_signature = {
  name : string;
  arity : int;
  arguments : argument_signature list;
  count : int;
  examples : Value.t list list;
}

type t = {
  predicates : predicate_signature list;
  by_name : (string, predicate_signature) Hashtbl.t;
  fingerprint : string;
  language_version : string;
}

let language_version = "beingdb-dsl/1"

let canonical_predicate_string (p : predicate_signature) =
  let arg_str =
    List.map
      (fun (a : argument_signature) ->
        Printf.sprintf "%d:%s" a.position (String.concat "|" (List.sort String.compare a.types)))
      p.arguments
  in
  Printf.sprintf "%s/%d[%s]" p.name p.arity (String.concat "," arg_str)

(** Deterministic fingerprint over canonical predicate metadata and the
    query-language generation version. Implemented with the stdlib
    [Digest] (MD5) rather than SHA-256 -- deterministic and
    dependency-free, consistent with how fact IDs are computed
    ({!Fact.fact_id}); not intended for adversarial contexts. *)
let compute_fingerprint predicates =
  let sorted = List.sort (fun (a : predicate_signature) b -> String.compare a.name b.name) predicates in
  let canonical = String.concat ";" (List.map canonical_predicate_string sorted) ^ "|" ^ language_version in
  "md5:" ^ Digest.to_hex (Digest.string canonical)

let build ?(examples = 3) store =
  let* names = Pack_backend.list_predicates store in
  let* predicate_opts =
    Lwt_list.map_s
      (fun name ->
        let* manifest_opt = Pack_backend.get_manifest store name in
        match manifest_opt with
        | None -> Lwt.return None
        | Some (m : Manifest.t) ->
            let arguments =
              List.mapi
                (fun i (p : Manifest.position_stat) -> { position = i; types = List.map fst p.type_stats })
                m.positions
            in
            let* samples = Pack_backend.sample_facts ~limit:examples store name in
            let examples_v = List.map (fun (f : Fact.t) -> f.arguments) samples in
            Lwt.return (Some { name; arity = m.arity; arguments; count = m.fact_count; examples = examples_v }))
      names
  in
  let predicates = List.filter_map (fun x -> x) predicate_opts in
  let by_name = Hashtbl.create 64 in
  List.iter (fun p -> Hashtbl.replace by_name p.name p) predicates;
  let fingerprint = compute_fingerprint predicates in
  Lwt.return { predicates; by_name; fingerprint; language_version }

let load_or_build ?examples store = build ?examples store
let find t name = Hashtbl.find_opt t.by_name name
let known_names t = List.map (fun p -> (p.name, p.arity)) t.predicates
