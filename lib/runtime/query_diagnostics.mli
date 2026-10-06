(** Query_diagnostics: deterministic, data-aware diagnostics for a
    candidate DSL query, and the repairs BeingDB can prove.

    {!Dsl_lower} decides whether a query is valid. Diagnostics use the
    compiled facts and the predicate declarations to report what BeingDB
    can establish exactly about a query (valid or not):

    - ["unknown_constant"]: an atom that occurs in no fact at all.
    - ["constant_not_at_position"]: a literal that occurs in no fact of the
      predicate at that argument position (evidence: where it does occur).
    - ["disjoint_join"]: a variable joining two positive patterns at
      positions that share no value.
    - ["contradictory_negation"]: a [not] block that only repeats positive
      clauses.
    - ["singleton_variable"]: a named variable used once and neither
      projected nor ordered on (it matches anything, like [_]).
    - ["role_name_mismatch"]: a variable named after the declared role of a
      different argument of the same predicate.

    Severity ["error"] means the query as written provably returns no rows;
    a provably empty clause inside optional/alternative/negated scope is a
    ["warning"]. Diagnostics never change validity.

    Repairs are attached only when proven:

    - [Swap_arguments]: a positive pattern with an ungrounded literal for
      which exactly one swap of two positions grounds every literal.
    - [Replace_variable]: a positive singleton variable whose snake_case
      name is an atom occurring at exactly that position. *)

type severity = Error | Warning | Info
type scope = Positive | Optional_scope | Alternative_scope | Negated_scope

type repair =
  | Swap_arguments of { predicate : string; line : int; positions : int * int }
  | Replace_variable of { predicate : string; line : int; argument_position : int; variable : string; value : Value.t }

type t = {
  code : string;
  severity : severity;
  message : string;
  line : int option;
  predicate : string option;
  argument_position : int option;
  variable : string option;
  value : Value.t option;
  scope : scope option;
  evidence : (string * Yojson.Safe.t) list;
  repair : repair option;
}

(** camelCase JSON, matching {!Validation_error.to_json}: [code],
    [severity], [message] and, when known, [line], [predicate],
    [argumentPosition], [variable], [value], [scope], [evidence], [repair]. *)
val to_json : t -> Yojson.Safe.t

val repair_to_json : repair -> Yojson.Safe.t

(** A literal in DSL source syntax ([@1979], ["text"], [<uri>], [atom]). *)
val dsl_literal : Value.t -> string

(** [CulturalQuarter] -> [cultural_quarter], [BBC] -> [bbc]. *)
val snake_case : string -> string

module Make (Store : Runtime_store.S) : sig
  (** Diagnostics for a parsed query, ordered by source line. Reads the
      store only through {!Runtime_store.S} lookups. *)
  val diagnose : Store.t -> Query_environment.t -> Surface_ast.surface_query -> t list Lwt.t
end

(** The deduplicated repairs carried by a diagnostics list, in line order. *)
val repairs : t list -> repair list

(** [apply_repairs text surface repairs]: [text] with only the repaired
    patterns' lines re-rendered (indentation kept). [None] if there is
    nothing to repair or the result does not parse back to exactly the
    repaired query. *)
val apply_repairs : string -> Surface_ast.surface_query -> repair list -> string option

module Report (Store : Runtime_store.S) : sig
  (** The [diagnose] response body for a DSL query: [valid], [errors] and
      [warnings] (as validation reports them), [diagnostics],
      [provablyEmpty] and, when a repair is proven and applies cleanly,
      [repair] = [{query, applied}]. Transports append their own
      language/environment fields. *)
  val fields : Store.t -> Query_environment.t -> string -> (string * Yojson.Safe.t) list Lwt.t
end
