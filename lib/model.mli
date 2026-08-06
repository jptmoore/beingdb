(** Model: Domain models and business logic types *)

(** Predicate represents a named relation with a fixed arity *)
type predicate = {
  name: string;
  arity: int;
  sample_facts: Fact.t list option;
}

(** Fact represents a single instance of a predicate *)
type fact = Fact.t = {
  predicate: string;
  arguments: Value.t list;
}

(** Typed variable binding *)
type binding = (string * Value.t) list

(** Query result *)
type query_result = {
  variables: string list;
  bindings: binding list;
  total_count: int;
}

(** Create predicate from database tuple *)
val make_predicate : ?samples:Fact.t list option -> string -> int -> predicate

(** Create fact from predicate name and arguments *)
val make_fact : string -> Value.t list -> fact

(** Create query result *)
val make_query_result : string list -> binding list -> int -> query_result

(** Convert query engine result to domain query result *)
val of_query_engine_result : Query_engine.result -> query_result

(** Validate predicate name *)
val validate_predicate_name : string -> (unit, string) result

(** Validate fact arity matches predicate *)
val validate_fact_arity : predicate -> fact -> (unit, string) result

(** Data access methods - domain layer over Db *)

(** List all predicates *)
val list_predicates : Db.t -> predicate list Lwt.t

(** List predicates with sample facts *)
val list_predicates_with_samples : samples:int -> Db.t -> predicate list Lwt.t

(** Query facts for a predicate *)
val query_predicate : limit:int -> Db.t -> string -> fact list Lwt.t

(** Check if predicate exists *)
val predicate_exists : Db.t -> string -> bool Lwt.t

(** Execute query *)
val execute_query : Db.t -> Query_ast.query -> (query_result, string) result Lwt.t

(** Execute query with streaming *)
val execute_query_streaming :
  Db.t -> Query_ast.query -> offset:int -> limit:int -> (query_result, string) result Lwt.t
