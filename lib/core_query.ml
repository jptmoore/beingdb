(** Core_query: the single representation the planner/executor consume,
    regardless of which surface syntax (core or expressive) produced it.
    Both {!Query_parser} (core language) and {!Dsl_lower} (expressive
    language) produce a [Core_query.t]; there is exactly one planner
    ({!Query_planner}) and one executor ({!Query_engine}) underneath. *)

type order_direction = Ascending | Descending
type order_item = { variable : string; direction : order_direction }

type t = {
  query : Query_ast.query;
  projection : string list option;  (** [None] projects every query variable (core-language default). *)
  distinct : bool;
  order_by : order_item list;
  limit : int option;
  offset : int option;
}

(** Wrap a plain core-language query with the identity post-processing
    directives (project everything, no dedup/ordering/limit/offset). *)
let of_query query = { query; projection = None; distinct = false; order_by = []; limit = None; offset = None }

let projected_variables t = match t.projection with Some vs -> vs | None -> t.query.Query_ast.variables

(** Compare two values for ordering purposes: prefer the type-aware
    {!Value.order_compare}, falling back to comparing canonical strings
    for types that have no defined order (e.g. atoms) -- [order by] must
    produce *some* deterministic total order for any bound variable. *)
let compare_values a b = match Value.order_compare a b with Ok c -> c | Error _ -> String.compare (Value.canonical_string a) (Value.canonical_string b)

(** Missing values (a variable left unbound by an unmatched [optional]
    branch) always sort after any present value -- "nulls last" -- for
    both [ascending] and [descending], per the documented ordering
    policy (see docs/query-language.md). *)
let apply_order_by order_by (bindings : Query_engine.binding list) =
  if order_by = [] then bindings
  else
    let cmp b1 b2 =
      let rec go = function
        | [] -> 0
        | (item : order_item) :: rest ->
            let c =
              match (List.assoc_opt item.variable b1, List.assoc_opt item.variable b2) with
              | None, None -> 0
              | None, Some _ -> 1
              | Some _, None -> -1
              | Some x, Some y -> (
                  let base = compare_values x y in
                  match item.direction with Ascending -> base | Descending -> -base)
            in
            if c <> 0 then c else go rest
      in
      go order_by
    in
    List.stable_sort cmp bindings

let tuple_equal t1 t2 =
  try
    List.for_all2 (fun a b -> match (a, b) with None, None -> true | Some x, Some y -> Value.equal x y | _ -> false) t1 t2
  with Invalid_argument _ -> false

(** Preserve-order dedup on projected tuples (not merely adjacent
    duplicates), using type-aware value equality. *)
let dedupe tuples =
  let seen = ref [] in
  List.filter
    (fun tuple ->
      if List.exists (tuple_equal tuple) !seen then false
      else (
        seen := tuple :: !seen;
        true))
    tuples

let take n l =
  let rec go n = function [] -> [] | _ when n <= 0 -> [] | x :: tl -> x :: go (n - 1) tl in
  go n l

let drop n l =
  let rec go n = function [] -> [] | l when n <= 0 -> l | _ :: tl -> go (n - 1) tl in
  go n l

(** Run the full post-execution pipeline over a raw {!Query_engine.result}:
    order by full binding, project to the requested variables, dedupe on
    the projected tuple (if [distinct]), then apply offset/limit. Returns
    the projected variable names alongside the resulting rows (each cell
    [None] if that variable was left unbound by an unmatched [optional]
    branch). *)
let apply (t : t) (result : Query_engine.result) =
  let ordered = apply_order_by t.order_by result.bindings in
  let vars = projected_variables t in
  let projected = List.map (fun binding -> List.map (fun v -> List.assoc_opt v binding) vars) ordered in
  let deduped = if t.distinct then dedupe projected else projected in
  let after_offset = match t.offset with Some n -> drop n deduped | None -> deduped in
  let sliced = match t.limit with Some n -> take n after_offset | None -> after_offset in
  (vars, sliced)
