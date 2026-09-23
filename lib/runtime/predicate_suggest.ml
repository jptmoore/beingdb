(** See {!Predicate_suggest} (mli) for documentation. *)

let normalize name = String.lowercase_ascii name |> String.map (function '-' -> '_' | c -> c)

let tokens name = String.split_on_char '_' (normalize name) |> List.filter (( <> ) "")

(** Classic Levenshtein edit distance (insert/delete/substitute), O(n*m). *)
let edit_distance a b =
  let la = String.length a and lb = String.length b in
  let d = Array.make_matrix (la + 1) (lb + 1) 0 in
  for i = 0 to la do
    d.(i).(0) <- i
  done;
  for j = 0 to lb do
    d.(0).(j) <- j
  done;
  for i = 1 to la do
    for j = 1 to lb do
      let cost = if a.[i - 1] = b.[j - 1] then 0 else 1 in
      d.(i).(j) <- min (min (d.(i - 1).(j) + 1) (d.(i).(j - 1) + 1)) (d.(i - 1).(j - 1) + cost)
    done
  done;
  d.(la).(lb)

let token_overlap a b =
  let ta = tokens a and tb = tokens b in
  if ta = [] || tb = [] then 0.0
  else
    let inter = List.filter (fun t -> List.mem t tb) ta |> List.sort_uniq String.compare |> List.length in
    let union = List.sort_uniq String.compare (ta @ tb) |> List.length in
    float_of_int inter /. float_of_int union

let suggest ?arity ~known name =
  let normalized_name = normalize name in
  let score (candidate, candidate_arity) =
    let normalized_candidate = normalize candidate in
    let exact_normalized = if normalized_candidate = normalized_name then 0.0 else 1.0 in
    let dist = float_of_int (edit_distance normalized_name normalized_candidate) in
    let overlap = token_overlap normalized_name candidate in
    let arity_bonus = match arity with Some a when a = candidate_arity -> 0.0 | Some _ -> 1.0 | None -> 0.0 in
    (* Lower is better: exact-normalized match first, then edit distance
       (scaled down by token overlap), then arity compatibility. *)
    (exact_normalized *. 100.0) +. (dist -. (overlap *. 3.0)) +. (arity_bonus *. 0.5)
  in
  let max_distance = max 3 (String.length normalized_name / 2) in
  known
  |> List.filter (fun (candidate, _) ->
         let normalized_candidate = normalize candidate in
         edit_distance normalized_name normalized_candidate <= max_distance || token_overlap normalized_name candidate > 0.0)
  |> List.map (fun p -> (p, score p))
  |> List.sort (fun (p1, s1) (p2, s2) -> if s1 <> s2 then compare s1 s2 else compare (fst p1) (fst p2))
  |> List.map (fun ((name, _), _) -> name)
  |> List.filteri (fun i _ -> i < 5)
