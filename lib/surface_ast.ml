(** Surface_ast: the parsed form of the expressive query language's
    textual syntax, before validation/lowering against a
    {!Query_environment}. Source line numbers are retained on leaf
    clauses so {!Dsl_lower} can produce precise error locations. *)

type surface_clause =
  | Pattern of { predicate : string; arguments : Query_ast.term list; line : int; column : int }
  | Compare of { left : Query_ast.term; operator : Query_ast.comparison_operator; right : Query_ast.term; line : int; column : int }
  | Between of { value : Query_ast.term; lower : Query_ast.term; upper : Query_ast.term; line : int; column : int }
  | Optional of surface_clause list
  | Alternatives of surface_clause list list
  | Negation of surface_clause list

type projection = { variables : string list; distinct : bool }

type surface_query = {
  projection : projection;
  where_ : surface_clause list;
  order_by : Core_query.order_item list;
  limit : int option;
  offset : int option;
}
