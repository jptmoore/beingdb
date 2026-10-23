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

(** [count_column "Work"] = ["count(Work)"]: the column name of a count. *)
val count_column : string -> string

(** [counted_variable "count(Work)"] = [Some "Work"]; [None] for a plain
    variable column. *)
val counted_variable : string -> string option

(** Whether any projected column is a count. *)
val is_count_query : t -> bool

(** Run the post-execution pipeline (order by, project, distinct-dedupe,
    offset/limit) over a raw execution result. For a count query, rows are
    grouped by the plain columns (one row overall when there are none, even
    with no matches), each [count(V)] cell is the number of distinct non-null
    values of [V] in the group (an [integer]), and order by/offset/limit
    apply to those rows. Returns the projected
    variable names and the resulting rows; a cell is [None] where an
    unmatched [optional] branch left that variable unbound. *)
val apply : t -> Query_engine.result -> string list * Value.t option list list
