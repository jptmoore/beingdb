(** Query AST: structured representation produced by the query parser. *)

type term = Variable of string | Wildcard | Literal of Value.t

type comparison_operator = Eq | Ne | Lt | Le | Gt | Ge

val string_of_operator : comparison_operator -> string

(** Flip an operator for the case [literal OP variable] so it can be
    treated uniformly as [variable OP' literal]. *)
val flip_operator : comparison_operator -> comparison_operator

type clause =
  | Pattern of { predicate : string; arguments : term list }
  | Compare of { left : term; operator : comparison_operator; right : term }
  | Between of { value : term; lower : term; upper : term }
  | Optional of clause list
  | Alternatives of clause list list
  | Not_exists of clause list

type query = { clauses : clause list; variables : string list }

val term_to_string : term -> string
val clause_to_string : clause -> string
val query_to_string : query -> string
val variables_of_term : term -> string list

(** All distinct variables referenced anywhere in the clause list, sorted. *)
val extract_variables : clause list -> string list

(** Every [Pattern] anywhere in the clause tree, including inside nested
    groups; each result is [(predicate, arguments)]. *)
val all_patterns : clause list -> (string * term list) list
