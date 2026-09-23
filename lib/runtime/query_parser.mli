(** Query_parser: parse the BeingDB query language into a structured AST. *)

(** Convenience alias so callers may write [Query_parser.query]. *)
type query = Query_ast.query = { clauses : Query_ast.clause list; variables : string list }

(** Parse a complete query string into a structured AST. Returns [None] on
    any parse error (syntax error, invalid literal, etc). Use
    {!parse_query_result} to get the error message. *)
val parse_query : string -> query option

(** Like {!parse_query}, but returns [Error msg] with a description of the
    parse failure instead of discarding it. *)
val parse_query_result : string -> (query, string) result
