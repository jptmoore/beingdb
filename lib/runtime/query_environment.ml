(** See {!Query_environment} (mli) for documentation. *)

open Lwt.Syntax

type argument_signature = { position : int; types : string list; role : string option; semantic_type : string option }

type predicate_signature = {
  name : string;
  arity : int;
  arguments : argument_signature list;
  count : int;
  examples : Value.t list list;
  description : string option;
}

type t = {
  predicates : predicate_signature list;
  by_name : (string, predicate_signature) Hashtbl.t;
  fingerprint : string;
  language_version : string;
}

let language_version = "beingdb-dsl/1"

let declared (p : predicate_signature) =
  p.description <> None || List.exists (fun (a : argument_signature) -> a.role <> None) p.arguments

(* Declared metadata is appended only when present, so environments
   without declarations keep the fingerprint they had before
   declarations existed. *)
let canonical_predicate_string (p : predicate_signature) =
  let arg_str =
    List.map
      (fun (a : argument_signature) ->
        Printf.sprintf "%d:%s" a.position (String.concat "|" (List.sort String.compare a.types)))
      p.arguments
  in
  let base = Printf.sprintf "%s/%d[%s]" p.name p.arity (String.concat "," arg_str) in
  if not (declared p) then base
  else
    let opt = function Some s -> `String s | None -> `Null in
    let decl =
      `List
        (opt p.description
        :: List.map (fun (a : argument_signature) -> `List [ opt a.role; opt a.semantic_type ]) p.arguments)
    in
    base ^ "#" ^ Yojson.Safe.to_string decl

(** Deterministic fingerprint over canonical predicate metadata and the
    query-language generation version: SHA-256 of a canonical string
    built from sorted predicate names, arities, observed argument types
    and any declared roles, semantic types and descriptions (so it is
    independent of any hash-table/map iteration order), plus the
    expressive-language version. Formatted as
    ["sha256:<lowercase hex digest>"]. *)
let compute_fingerprint predicates =
  let sorted = List.sort (fun (a : predicate_signature) b -> String.compare a.name b.name) predicates in
  let canonical = String.concat ";" (List.map canonical_predicate_string sorted) ^ "|" ^ language_version in
  "sha256:" ^ Digestif.SHA256.to_hex (Digestif.SHA256.digest_string canonical)

let signature_of_manifest ~name ~examples (m : Manifest.t) =
  (* A declaration whose arity disagrees with the facts is never written
     by the compiler; ignore one defensively rather than mislabel. *)
  let declaration =
    match m.declaration with Some d when Predicate_declaration.arity d = m.arity -> Some d | _ -> None
  in
  let declared_argument i =
    match declaration with Some d -> List.nth_opt d.Predicate_declaration.arguments i | None -> None
  in
  let arguments =
    List.mapi
      (fun i (p : Manifest.position_stat) ->
        let role, semantic_type =
          match declared_argument i with
          | Some a -> (Some a.Predicate_declaration.role, a.Predicate_declaration.semantic_type)
          | None -> (None, None)
        in
        { position = i; types = List.map fst p.type_stats; role; semantic_type })
      m.positions
  in
  let description = Option.bind declaration (fun d -> d.Predicate_declaration.description) in
  { name; arity = m.arity; arguments; count = m.fact_count; examples; description }

module Make (Store : Runtime_store.S) = struct
  let build ?(examples = 3) store =
    let* names = Store.list_predicates store in
    let* predicate_opts =
      Lwt_list.map_s
        (fun name ->
          let* manifest_opt = Store.get_manifest store name in
          match manifest_opt with
          | None -> Lwt.return None
          | Some m ->
              let* samples = Store.sample_facts ~limit:examples store name in
              let examples = List.map (fun (f : Fact.t) -> f.arguments) samples in
              Lwt.return (Some (signature_of_manifest ~name ~examples m)))
        names
    in
    let predicates = List.filter_map (fun x -> x) predicate_opts in
    let by_name = Hashtbl.create 64 in
    List.iter (fun p -> Hashtbl.replace by_name p.name p) predicates;
    let fingerprint = compute_fingerprint predicates in
    Lwt.return { predicates; by_name; fingerprint; language_version }

  let load_or_build ?examples store = build ?examples store
end

let find t name = Hashtbl.find_opt t.by_name name
let known_names t = List.map (fun p -> (p.name, p.arity)) t.predicates

let argument_to_json (a : argument_signature) =
  `Assoc
    ([ ("position", `Int a.position); ("types", `List (List.map (fun t -> `String t) a.types)) ]
    @ (match a.role with Some r -> [ ("role", `String r) ] | None -> [])
    @ match a.semantic_type with Some ty -> [ ("semanticType", `String ty) ] | None -> [])

let predicate_to_json (p : predicate_signature) =
  `Assoc
    ([ ("name", `String p.name); ("arity", `Int p.arity); ("count", `Int p.count) ]
    @ (match p.description with Some d -> [ ("description", `String d) ] | None -> [])
    @ [
        ("arguments", `List (List.map argument_to_json p.arguments));
        ("examples", `List (List.map (fun args -> `List (List.map Value.to_json args)) p.examples));
      ])

let to_json ?predicates t =
  let predicates = Option.value predicates ~default:t.predicates in
  `Assoc
    [
      ("predicates", `List (List.map predicate_to_json predicates));
      ("environmentFingerprint", `String t.fingerprint);
      ("languageVersion", `String t.language_version);
    ]
