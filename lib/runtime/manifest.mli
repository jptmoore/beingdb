(** Per-predicate schema manifest, recorded at compile time.

    Arity, counts and per-position type statistics are inferred purely
    from the compiled facts and used for introspection and query
    planning. [declaration] optionally carries the author's
    {!Predicate_declaration} from the source file; it is documentation
    only and never affects typing or query execution. *)

type type_stat = { count : int; distinct_count : int; min : string option; max : string option }

(** Per-argument-position statistics, one [type_stat] per distinct type
    observed at that position (mixed-type positions get multiple
    entries). *)
type position_stat = { type_stats : (string * type_stat) list }

type t = {
  arity : int;
  fact_count : int;
  positions : position_stat list;
  declaration : Predicate_declaration.t option;
}

(** Compute a manifest from the complete set of facts for one predicate.
    [facts] must all share the same predicate name (the caller is
    responsible for grouping). [declaration] is stored as given; callers
    are responsible for checking that its arity matches the facts. *)
val compute : ?declaration:Predicate_declaration.t -> Fact.t list -> t

(** The ["declaration"] field is written only when present, so manifests
    without one are byte-identical to those written before declarations
    existed. *)
val to_json : t -> Yojson.Safe.t

(** A missing or malformed ["declaration"] field reads as [None]. *)
val of_json : Yojson.Safe.t -> (t, string) result
