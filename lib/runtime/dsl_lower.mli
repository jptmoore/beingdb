(** Validate a {!Surface_ast.surface_query} against a
    {!Query_environment} and lower it into a {!Core_query.t}. Every
    problem found is reported (not just the first). If [errors] is
    non-empty, [core_query] is [None] and must not be executed. *)

type result = { core_query : Core_query.t option; errors : Validation_error.t list; warnings : Validation_error.warning list }

val lower : Query_environment.t -> Surface_ast.surface_query -> result
