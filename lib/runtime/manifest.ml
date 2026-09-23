(** See {!Manifest} (mli) for documentation. *)

type type_stat = { count : int; distinct_count : int; min : string option; max : string option }
type position_stat = { type_stats : (string * type_stat) list }
type t = { arity : int; fact_count : int; positions : position_stat list }

let compute_type_stat values =
  let count = List.length values in
  let distinct_count =
    let tbl = Hashtbl.create 16 in
    List.iter (fun v -> Hashtbl.replace tbl (Value.canonical_string v) ()) values;
    Hashtbl.length tbl
  in
  let min, max =
    match values with
    | [] -> (None, None)
    | first :: rest ->
        let fold_extreme pick acc v =
          match Value.order_compare v acc with
          | Ok c -> if pick c then v else acc
          | Error _ -> acc
        in
        let min_v = List.fold_left (fold_extreme (fun c -> c < 0)) first rest in
        let max_v = List.fold_left (fold_extreme (fun c -> c > 0)) first rest in
        (Some (Value.canonical_string min_v), Some (Value.canonical_string max_v))
  in
  { count; distinct_count; min; max }

let compute facts =
  let arity = match facts with f :: _ -> List.length f.Fact.arguments | [] -> 0 in
  let fact_count = List.length facts in
  let positions =
    List.init arity (fun pos ->
        let values = List.map (fun f -> List.nth f.Fact.arguments pos) facts in
        let by_type = Hashtbl.create 8 in
        List.iter
          (fun v ->
            let tn = Value.type_name v in
            let existing = try Hashtbl.find by_type tn with Not_found -> [] in
            Hashtbl.replace by_type tn (v :: existing))
          values;
        let type_stats =
          Hashtbl.fold (fun tn vs acc -> (tn, compute_type_stat (List.rev vs)) :: acc) by_type []
          |> List.sort (fun (a, _) (b, _) -> String.compare a b)
        in
        { type_stats })
  in
  { arity; fact_count; positions }

let type_stat_to_json (tn, s) =
  ( tn,
    `Assoc
      [
        ("count", `Int s.count);
        ("distinct_count", `Int s.distinct_count);
        ("min", match s.min with Some m -> `String m | None -> `Null);
        ("max", match s.max with Some m -> `String m | None -> `Null);
      ] )

let to_json t =
  `Assoc
    [
      ("arity", `Int t.arity);
      ("fact_count", `Int t.fact_count);
      ( "positions",
        `List
          (List.map
             (fun p -> `Assoc (List.map type_stat_to_json p.type_stats))
             t.positions) );
    ]

let type_stat_of_json = function
  | `Assoc fields ->
      let count = match List.assoc_opt "count" fields with Some (`Int n) -> n | _ -> 0 in
      let distinct_count =
        match List.assoc_opt "distinct_count" fields with Some (`Int n) -> n | _ -> 0
      in
      let min = match List.assoc_opt "min" fields with Some (`String s) -> Some s | _ -> None in
      let max = match List.assoc_opt "max" fields with Some (`String s) -> Some s | _ -> None in
      Ok { count; distinct_count; min; max }
  | _ -> Error "Invalid type_stat JSON"

let of_json json =
  match json with
  | `Assoc fields -> (
      match (List.assoc_opt "arity" fields, List.assoc_opt "fact_count" fields, List.assoc_opt "positions" fields) with
      | Some (`Int arity), Some (`Int fact_count), Some (`List position_jsons) ->
          let positions =
            List.map
              (function
                | `Assoc type_fields ->
                    let type_stats =
                      List.filter_map
                        (fun (tn, json) ->
                          match type_stat_of_json json with Ok s -> Some (tn, s) | Error _ -> None)
                        type_fields
                    in
                    { type_stats }
                | _ -> { type_stats = [] })
              position_jsons
          in
          Ok { arity; fact_count; positions }
      | _ -> Error "Invalid manifest JSON")
  | _ -> Error "Invalid manifest JSON"
