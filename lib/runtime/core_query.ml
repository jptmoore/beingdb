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

(* A count column is named after its source text: [count(Work)]. *)
let count_column variable = "count(" ^ variable ^ ")"

type aggregate = Count | Sum | Avg | Min | Max

let aggregate_name = function Count -> "count" | Sum -> "sum" | Avg -> "avg" | Min -> "min" | Max -> "max"
let aggregate_column f variable = aggregate_name f ^ "(" ^ variable ^ ")"

let aggregate_of column =
  let n = String.length column in
  match String.index_opt column '(' with
  | Some i when n > i + 2 && column.[n - 1] = ')' -> (
      let variable = String.trim (String.sub column (i + 1) (n - i - 2)) in
      match String.sub column 0 i with
      | "count" -> Some (Count, variable)
      | "sum" -> Some (Sum, variable)
      | "avg" -> Some (Avg, variable)
      | "min" -> Some (Min, variable)
      | "max" -> Some (Max, variable)
      | _ -> None)
  | _ -> None

let counted_variable column = match aggregate_of column with Some (Count, v) -> Some v | _ -> None
let is_aggregate_query t = List.exists (fun c -> aggregate_of c <> None) (projected_variables t)
let is_count_query = is_aggregate_query

(** Compare two values for ordering purposes: prefer the type-aware
    {!Value.order_compare}, falling back to comparing canonical strings
    for types that have no defined order (e.g. atoms) -- [order by] must
    produce *some* deterministic total order for any bound variable. *)
let compare_values a b = match Value.order_compare a b with Ok c -> c | Error _ -> String.compare (Value.canonical_string a) (Value.canonical_string b)

(** Missing values (a variable left unbound by an unmatched [optional]
    branch) always sort after any present value -- "nulls last" -- for
    both [ascending] and [descending], per the documented ordering
    policy (see docs/query-language.md). *)
let compare_bindings order_by (b1 : Query_engine.binding) (b2 : Query_engine.binding) =
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

let apply_order_by order_by (bindings : Query_engine.binding list) =
  if order_by = [] then bindings else List.stable_sort (compare_bindings order_by) bindings

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
    the projected tuple (if [distinct]), then apply offset/limit. A count
    query ({!is_count_query}) instead groups by its plain columns, counts,
    then orders by the output columns and applies offset/limit. Returns
    the projected variable names alongside the resulting rows (each cell
    [None] if that variable was left unbound by an unmatched [optional]
    branch). *)
let value_key v = Value.type_name v ^ ":" ^ Value.canonical_string v

(* ---- Aggregate arithmetic: exact, over int64 coefficients ---- *)

exception Overflow
exception Aggregate_overflow of string

let checked_add a b =
  let r = Int64.add a b in
  let nonneg x = Int64.compare x 0L >= 0 in
  if nonneg a = nonneg b && nonneg r <> nonneg a then raise Overflow else r

let checked_mul a b =
  if a = 0L || b = 0L then 0L
  else if (a = -1L && b = Int64.min_int) || (b = -1L && a = Int64.min_int) then raise Overflow
  else
    let r = Int64.mul a b in
    if Int64.div r b <> a then raise Overflow else r

let rec pow10 k = if k <= 0 then 1L else checked_mul 10L (pow10 (k - 1))

(* coefficient * 10^(-scale) *)
type number = { coefficient : int64; scale : int }

let number_of (v : Value.t) =
  match v with
  | Integer i -> Some ({ coefficient = i; scale = 0 }, false)
  | Decimal d -> Some ({ coefficient = Decimal.coefficient d; scale = Decimal.scale d }, true)
  | _ -> None

let add a b =
  let s = max a.scale b.scale in
  { coefficient = checked_add (checked_mul a.coefficient (pow10 (s - a.scale))) (checked_mul b.coefficient (pow10 (s - b.scale))); scale = s }

(* [total / n] with up to 6 more fractional digits (fewer if they would
   overflow), rounded half away from zero. *)
let mean total n =
  let n64 = Int64.of_int n in
  let rec attempt k =
    match checked_mul total.coefficient (pow10 k) with
    | exception Overflow when k > 0 -> attempt (k - 1)
    | scaled ->
        let q = Int64.div scaled n64 and r = Int64.rem scaled n64 in
        let q =
          if Int64.compare (Int64.mul (Int64.abs r) 2L) n64 >= 0 then if Int64.compare scaled 0L >= 0 then Int64.succ q else Int64.pred q
          else q
        in
        Decimal.make q (total.scale + k)
  in
  attempt 6

type accumulator =
  | Distinct of (string, unit) Hashtbl.t  (** count: distinct values *)
  | Total of { mutable sum : number option; mutable n : int; mutable decimal : bool }  (** sum, avg *)
  | Extreme of { mutable best : Value.t option }  (** min, max *)

let new_accumulator = function
  | Count -> Distinct (Hashtbl.create 8)
  | Sum | Avg -> Total { sum = None; n = 0; decimal = false }
  | Min | Max -> Extreme { best = None }

let accumulate column f acc (x : Value.t) =
  match acc with
  | Distinct set -> Hashtbl.replace set (value_key x) ()
  | Total t -> (
      match number_of x with
      | None -> ()
      | Some (num, decimal) ->
          (t.sum <- (match t.sum with None -> Some num | Some s -> Some (try add s num with Overflow -> raise (Aggregate_overflow (Printf.sprintf "%s overflows: the total does not fit in a 64-bit number" column)))));
          t.n <- t.n + 1;
          t.decimal <- t.decimal || decimal)
  | Extreme e ->
      if Value.is_ordered_type x then
        match e.best with
        | None -> e.best <- Some x
        | Some b -> (
            match Value.order_compare x b with
            | Ok c -> if (f = Min && c < 0) || (f = Max && c > 0) then e.best <- Some x
            | Error _ -> ())

let result f acc : Value.t option =
  match (f, acc) with
  | _, Distinct set -> Some (Value.Integer (Int64.of_int (Hashtbl.length set)))
  | Avg, Total { sum = Some s; n; _ } -> Some (Value.Decimal (mean s n))
  | _, Total { sum = Some s; decimal; _ } -> Some (if decimal then Value.Decimal (Decimal.make s.coefficient s.scale) else Value.Integer s.coefficient)
  | _, Total { sum = None; _ } -> None
  | _, Extreme { best } -> best

(* Rows of an aggregate query: one per distinct combination of the plain
   find columns (first-seen order). count(V) counts V's distinct non-null
   values; the other aggregates read each distinct solution (combination of
   the query's named variables) of the group once, so a join that repeats a
   solution does not inflate a sum. With no plain columns there is exactly
   one row, even when nothing matched. *)
let grouped_rows columns (bindings : Query_engine.binding list) =
  let group_columns = List.filter (fun c -> aggregate_of c = None) columns in
  let aggregates = List.filter_map (fun c -> Option.map (fun (f, v) -> (c, f, v)) (aggregate_of c)) columns in
  let fresh () = (Hashtbl.create 8, List.map (fun (c, f, v) -> (c, f, v, new_accumulator f)) aggregates) in
  let groups = Hashtbl.create 64 in
  let order = ref [] in
  let solution_key binding =
    List.sort compare (List.map (fun (v, x) -> v ^ "=" ^ value_key x) binding) |> String.concat "\x00"
  in
  List.iter
    (fun binding ->
      let key_values = List.map (fun c -> List.assoc_opt c binding) group_columns in
      let key = String.concat "\x00" (List.map (function Some v -> value_key v | None -> "-") key_values) in
      let seen, accs =
        match Hashtbl.find_opt groups key with
        | Some (_, state) -> state
        | None ->
            let state = fresh () in
            Hashtbl.replace groups key (key_values, state);
            order := key :: !order;
            state
      in
      let first_time =
        lazy
          (let k = solution_key binding in
           if Hashtbl.mem seen k then false
           else (
             Hashtbl.replace seen k ();
             true))
      in
      List.iter
        (fun (column, f, v, acc) ->
          match List.assoc_opt v binding with
          | None -> ()
          | Some x -> if f = Count || Lazy.force first_time then accumulate column f acc x)
        accs)
    bindings;
  let keys = if group_columns = [] && !order = [] then [ "" ] else List.rev !order in
  List.map
    (fun key ->
      let key_values, (_, accs) = match Hashtbl.find_opt groups key with Some g -> g | None -> ([], fresh ()) in
      let plain = ref key_values in
      List.map
        (fun column ->
          match List.find_opt (fun (c, _, _, _) -> c = column) accs with
          | Some (_, f, _, acc) -> result f acc
          | None -> (
              match !plain with
              | x :: rest ->
                  plain := rest;
                  x
              | [] -> None))
        columns)
    keys

let apply (t : t) (result : Query_engine.result) =
  if is_count_query t then (
    let columns = projected_variables t in
    let rows = grouped_rows columns result.bindings in
    let as_binding row = List.filter_map (fun (c, cell) -> Option.map (fun v -> (c, v)) cell) (List.combine columns row) in
    let ordered =
      if t.order_by = [] then rows else List.stable_sort (fun r1 r2 -> compare_bindings t.order_by (as_binding r1) (as_binding r2)) rows
    in
    let after_offset = match t.offset with Some n -> drop n ordered | None -> ordered in
    let sliced = match t.limit with Some n -> take n after_offset | None -> after_offset in
    (columns, sliced))
  else
  let ordered = apply_order_by t.order_by result.bindings in
  let vars = projected_variables t in
  let projected = List.map (fun binding -> List.map (fun v -> List.assoc_opt v binding) vars) ordered in
  let deduped = if t.distinct then dedupe projected else projected in
  let after_offset = match t.offset with Some n -> drop n deduped | None -> deduped in
  let sliced = match t.limit with Some n -> take n after_offset | None -> after_offset in
  (vars, sliced)
