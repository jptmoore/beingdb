type order_direction = Ascending | Descending
type order_item = { variable : string; direction : order_direction }

type t = {
  query : Query_ast.query;
  projection : string list option;
  distinct : bool;
  order_by : order_item list;
  limit : int option;
  offset : int option;
}

val of_query : Query_ast.query -> t

(** The variables to project: the explicit projection list, or every
    query variable when none was given. *)
val projected_variables : t -> string list

(** Run the post-execution pipeline (order by, project, distinct-dedupe,
    offset/limit) over a raw execution result. Returns the projected
    variable names and the resulting rows; a cell is [None] where an
    unmatched [optional] branch left that variable unbound. *)
val apply : t -> Query_engine.result -> string list * Value.t option list list
