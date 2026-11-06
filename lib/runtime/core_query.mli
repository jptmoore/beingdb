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
    variable column or another aggregate. *)
val counted_variable : string -> string option

(** The aggregate functions of [find]: [count(V)] counts the distinct
    values of [V]; [sum(V)], [avg(V)], [min(V)] and [max(V)] are computed
    over the group's distinct solutions (distinct combinations of the
    query's named variables). *)
type aggregate = Count | Sum | Avg | Min | Max

(** ["count"], ["sum"], ["avg"], ["min"], ["max"]. *)
val aggregate_name : aggregate -> string

(** [aggregate_column Sum "Value"] = ["sum(Value)"]. *)
val aggregate_column : aggregate -> string -> string

(** [aggregate_of "sum(Value)"] = [Some (Sum, "Value")]; [None] for a plain
    variable column. *)
val aggregate_of : string -> (aggregate * string) option

(** Whether any projected column is an aggregate ([count], [sum], [avg],
    [min] or [max]). *)
val is_aggregate_query : t -> bool

(** Same as {!is_aggregate_query} (kept from when [count] was the only
    aggregate). *)
val is_count_query : t -> bool

(** A sum that does not fit in a 64-bit coefficient; carries a message
    naming the column. *)
exception Aggregate_overflow of string

(** Run the post-execution pipeline (order by, project, distinct-dedupe,
    offset/limit) over a raw execution result. For an aggregate query,
    rows are grouped by the plain columns (one row overall when there are
    none, even with no matches) and order by/offset/limit apply to those
    rows. In each group:
    - [count(V)]: the number of distinct non-null values of [V] ([integer]);
    - [sum(V)]: the sum of the [integer]/[decimal] values of [V] over the
      group's distinct solutions ([integer] if all are integers, else
      [decimal]);
    - [avg(V)]: their mean, a [decimal] rounded to at most 6 more fractional
      digits than the inputs;
    - [min(V)]/[max(V)]: the least/greatest ordered value ([integer],
      [decimal], [year], [year_month], [date], [instant]); a value that
      cannot be compared with the current one is skipped.
    Values of other types are ignored; with none left the cell is [None].
    Raises {!Aggregate_overflow} if a sum overflows a 64-bit coefficient. Returns the
    projected variable names and the resulting rows; a cell is [None] where
    an unmatched [optional] branch left that variable unbound. *)
val apply : t -> Query_engine.result -> string list * Value.t option list list
