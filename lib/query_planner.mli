(** Query_planner: turns a parsed query into an explainable execution
    plan. See the .ml for design notes. *)

type bound = { lower : (Value.t * bool) option; upper : (Value.t * bool) option }

type var_constraint = Eq_constraint of Value.t | Range_constraint of bound

type arg_plan =
  | Constant of Value.t
  | Wildcard_arg
  | Bound_variable of string
  | Free_variable of string * var_constraint option

type access =
  | Equality_index of { position : int; value : Value.t }
  | Equality_index_on_variable of { position : int; var : string }
  | Range_index of { position : int; lower : (Value.t * bool) option; upper : (Value.t * bool) option }
  | Full_scan

type step = { predicate : string; args : arg_plan list; access : access }

type t = { steps : step list; post_filters : Query_ast.clause list; variables : string list }

(** Build an execution plan from a parsed query. Pure: does not touch the
    store. *)
val plan : Query_ast.query -> t

(** Human-readable explanation of the chosen access method per step. *)
val explain : t -> string
