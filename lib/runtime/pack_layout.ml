(** See {!Pack_layout} (mli) for the layout.

    Range queries enumerate every distinct index key within the relevant
    type branch(es) (not a full predicate scan), then fetch and decode
    the candidate facts to confirm exact comparison results. This is a
    documented, deliberate first-implementation choice: index keys are
    stored using a fixed-width, lexicographically sortable encoding (see
    {!Value.sortable_string}) so that a future implementation can add
    genuine sorted range scans without changing the on-disk encoding;
    this implementation does not yet exploit that ordering to skip
    out-of-range candidates within a branch, since Irmin-Pack's inode
    child ordering is hash-seeded and not guaranteed to reflect insertion
    or lexicographic order. *)

open Lwt.Syntax

type path = string list

let facts_path fact_id = [ "facts"; fact_id ]
let meta_path predicate = [ "meta"; predicate ]
let index_all_dir predicate = [ "index"; predicate; "_all" ]

let index_key_dir predicate position type_tag key =
  [ "index"; predicate; string_of_int position; type_tag; key ]

let index_type_branch predicate position type_tag =
  [ "index"; predicate; string_of_int position; type_tag ]

let fact_entries (fact : Fact.t) =
  let fact_id = Fact.fact_id fact in
  (facts_path fact_id, Fact.encode fact)
  :: (index_all_dir fact.predicate @ [ fact_id ], "")
  :: List.mapi
       (fun pos arg -> (index_key_dir fact.predicate pos (Value.type_name arg) (Value.index_key arg) @ [ fact_id ], ""))
       fact.arguments

let predicate_entries predicate facts =
  let manifest = Manifest.compute facts in
  List.concat_map fact_entries facts
  @ [ (meta_path predicate, Yojson.Safe.to_string (Manifest.to_json manifest)) ]

module type READER = sig
  type t

  val find : t -> path -> string option Lwt.t
  val list : t -> path -> string list Lwt.t
end

(* Type branches consulted for a range bound of the given value's type.
   Integer and decimal form one numeric family (with promotion); other
   ordered types are compared only within their own type, per spec (years
   are never silently compared against dates, etc). *)
let type_family = function
  | Value.Integer _ | Value.Decimal _ -> [ "integer"; "decimal" ]
  | Value.Year _ -> [ "year" ]
  | Value.Year_month _ -> [ "year_month" ]
  | Value.Date _ -> [ "date" ]
  | Value.Instant _ -> [ "instant" ]
  | other -> [ Value.type_name other ]

let within_bounds ~lower ~upper v =
  let check bound_opt cmp_ok =
    match bound_opt with
    | None -> Ok true
    | Some (bound, inclusive) -> (
        match Value.order_compare v bound with
        | Ok c -> Ok (cmp_ok inclusive c)
        | Error e -> if Value.is_ordered_type v then Error e else Ok false)
  in
  match (check lower (fun incl c -> if incl then c >= 0 else c > 0), check upper (fun incl c -> if incl then c <= 0 else c < 0)) with
  | Ok true, Ok true -> Ok true
  | Ok _, Ok _ -> Ok false
  | Error e, _ | _, Error e -> Error e

let take n lst =
  let rec go n = function [] -> [] | x :: xs when n > 0 -> x :: go (n - 1) xs | _ -> [] in
  go n lst

module Make (R : READER) = struct
  type t = R.t

  (* --- reading facts --- *)

  let get_fact store fact_id =
    let* value_opt = R.find store (facts_path fact_id) in
    match value_opt with
    | None -> Lwt.return None
    | Some encoded -> ( match Fact.decode encoded with Ok f -> Lwt.return (Some f) | Error _ -> Lwt.return None)

  let facts_of_ids store ids = Lwt_list.filter_map_s (fun id -> get_fact store id) ids

  (* --- introspection --- *)

  let list_predicates store = R.list store [ "meta" ]

  let get_manifest store predicate =
    let* value_opt = R.find store (meta_path predicate) in
    match value_opt with
    | None -> Lwt.return None
    | Some json_str -> (
        match Manifest.of_json (Yojson.Safe.from_string json_str) with
        | Ok m -> Lwt.return (Some m)
        | Error _ -> Lwt.return None)

  (* --- predicate scans --- *)

  let query_all store predicate =
    let* ids = R.list store (index_all_dir predicate) in
    facts_of_ids store ids

  let query_all_limited ?(limit = 1000) store predicate =
    let* ids = R.list store (index_all_dir predicate) in
    facts_of_ids store (take limit ids)

  let sample_facts ?(limit = 20) store predicate =
    let* ids = R.list store (index_all_dir predicate) in
    facts_of_ids store (take limit ids)

  let predicate_fact_count store predicate =
    let* m = get_manifest store predicate in
    match m with Some m -> Lwt.return m.Manifest.fact_count | None -> Lwt.return 0

  let predicate_arity store predicate =
    let* m = get_manifest store predicate in
    match m with Some m -> Lwt.return m.Manifest.arity | None -> Lwt.return 0

  (* --- indexed lookups --- *)

  let equality_lookup store predicate position value =
    let type_tag = Value.type_name value in
    let key = Value.index_key value in
    let* ids = R.list store (index_key_dir predicate position type_tag key) in
    let* candidates = facts_of_ids store ids in
    (* Defensive re-verification: guards against the (extremely unlikely)
       case of a hashed-key collision for long string-like values. *)
    Lwt.return
      (List.filter
         (fun (f : Fact.t) ->
           match List.nth_opt f.arguments position with Some v -> Value.equal v value | None -> false)
         candidates)

  (* Gather every type branch that could plausibly hold a comparable value:
     the bound's own numeric/temporal family, plus every type actually
     observed at this predicate/position (from the schema manifest). This
     ensures that a genuine type mismatch (e.g. a date compared with an
     integer) is detected against real stored data rather than silently
     returning zero results, while values of a fundamentally non-ordered
     type (e.g. a string sharing a mixed-type position with integers) are
     still silently excluded rather than treated as an error. *)
  let branches_to_scan store predicate position bound =
    let* manifest = get_manifest store predicate in
    let observed =
      match manifest with
      | None -> []
      | Some m -> (
          match List.nth_opt m.Manifest.positions position with
          | Some p -> List.map fst p.Manifest.type_stats
          | None -> [])
    in
    Lwt.return (List.sort_uniq String.compare (type_family bound @ observed))

  let range_lookup store predicate position ~lower ~upper =
    let sample_bound =
      match (lower, upper) with Some (v, _), _ -> Some v | _, Some (v, _) -> Some v | None, None -> None
    in
    match sample_bound with
    | None -> Lwt.return (Ok [])
    | Some bound ->
        let* branches = branches_to_scan store predicate position bound in
        let* ids_lists =
          Lwt_list.map_s
            (fun type_tag ->
              let branch = index_type_branch predicate position type_tag in
              let* keys = R.list store branch in
              Lwt_list.fold_left_s
                (fun acc key ->
                  let* fact_ids = R.list store (branch @ [ key ]) in
                  Lwt.return (fact_ids @ acc))
                [] keys)
            branches
        in
        let ids = List.concat ids_lists in
        let* candidates = facts_of_ids store ids in
        let rec filter = function
          | [] -> Ok []
          | (f : Fact.t) :: rest -> (
              match List.nth_opt f.arguments position with
              | None -> filter rest
              | Some v -> (
                  match within_bounds ~lower ~upper v with
                  | Error e -> Error e
                  | Ok false -> filter rest
                  | Ok true -> ( match filter rest with Ok fs -> Ok (f :: fs) | Error _ as e -> e)))
        in
        Lwt.return (filter candidates)

  (* Uses the equality index on the first constrained position when one
     exists, falling back to a full predicate scan otherwise. *)
  let query_predicate_pattern store predicate pattern =
    let indexed_position =
      List.mapi (fun i v -> (i, v)) pattern |> List.find_opt (fun (_, v) -> Option.is_some v)
    in
    let* candidates =
      match indexed_position with
      | Some (pos, Some v) -> equality_lookup store predicate pos v
      | _ -> query_all store predicate
    in
    Lwt.return
      (List.filter
         (fun (f : Fact.t) ->
           List.length f.arguments = List.length pattern
           &&
           try
             List.for_all2
               (fun expected actual -> match expected with None -> true | Some v -> Value.equal v actual)
               pattern f.arguments
           with Invalid_argument _ -> false)
         candidates)
end
