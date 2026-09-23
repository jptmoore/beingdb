(** Parse the expressive query language's textual syntax into a
    {!Surface_ast.surface_query}, or an error message (including a
    1-based source line number where applicable). *)
val parse : string -> (Surface_ast.surface_query, string) result
