(** Shared clause-level parsing used by both the core and expressive
    query languages. *)

(** Interpret a single token as a {!Query_ast.term}: [Underscore] is the
    wildcard, an [Ident] starting with an uppercase letter (other than
    [true]/[false]) is a variable, and anything else is a typed literal. *)
val term_of_token : Lexer.token -> (Query_ast.term, string) result

(** Split a token list on top-level [Comma] tokens (commas nested inside
    a predicate's own parentheses are not top-level). *)
val split_top_level_commas : Lexer.token list -> Lexer.token list list

val operator_of_string : string -> Query_ast.comparison_operator option

(** Parse one clause's worth of tokens (already comma-split, if
    applicable) into a predicate pattern, comparison, or between-clause. *)
val parse_clause_tokens : Lexer.token list -> (Query_ast.clause, string) result
