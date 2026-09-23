(** Schema inference: per-predicate metadata inferred at compile time.
    Users never author this manifest; it is purely observational
    information recorded from the compiled facts, used to answer
    introspection queries and to help the query planner. *)

type type_stat = { count : int; distinct_count : int; min : string option; max : string option }

(** Per-argument-position statistics, one [type_stat] per distinct type
    observed at that position (mixed-type positions get multiple
    entries). *)
type position_stat = { type_stats : (string * type_stat) list }

type t = { arity : int; fact_count : int; positions : position_stat list }

(** Compute a manifest from the complete set of facts for one predicate.
    [facts] must all share the same predicate name (the caller is
    responsible for grouping). *)
val compute : Fact.t list -> t

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
