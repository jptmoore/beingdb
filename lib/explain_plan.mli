(** Build the structured, machine-readable [plan] array for a lowered
    query (the human-readable [Query_engine.explain] prose remains
    available separately as [planText]). *)
val build : Core_query.t -> Yojson.Safe.t list

(** [{"patterns": [...], "comparisons": [...]}] rendering of a core
    query's clauses, for the explain response's [normalizedCoreQuery]
    field. *)
val normalized_core_query_json : Query_ast.query -> Yojson.Safe.t
