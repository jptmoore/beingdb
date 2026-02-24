(** Model: Domain models and business logic types *)

(** Predicate represents a named relation with a fixed arity *)
type predicate = {
  name: string;
  arity: int;
  sample_facts: Types.arg_value list list option;
}

(** Fact represents a single instance of a predicate *)
type fact = {
  predicate: string;
  arguments: Types.arg_value list;
}

(** Query result binding *)
type binding = (string * string) list

(** Query result *)
type query_result = {
  variables: string list;
  bindings: binding list;
  total_count: int;
}

(** Create predicate from database tuple *)
let make_predicate ?(samples=None) name arity =
  { name; arity; sample_facts = samples }

(** Create fact from predicate name and arguments *)
let make_fact predicate arguments =
  { predicate; arguments }

(** Create query result *)
let make_query_result variables bindings total_count =
  { variables; bindings; total_count }

(** Convert query engine result to domain query result *)
let of_query_engine_result (result: Query_engine.result) =
  {
    variables = result.Query_engine.variables;
    bindings = result.Query_engine.bindings;
    total_count = List.length result.Query_engine.bindings;
  }

(** Validate predicate name *)
let validate_predicate_name name =
  if String.length name = 0 then
    Error "Predicate name cannot be empty"
  else if String.contains name ' ' then
    Error "Predicate name cannot contain spaces"
  else
    Ok ()

(** Validate fact arity matches predicate *)
let validate_fact_arity predicate fact =
  if List.length fact.arguments <> predicate.arity then
    Error (Printf.sprintf "Expected %d arguments, got %d" 
      predicate.arity (List.length fact.arguments))
  else
    Ok ()

(** Data access methods - wrapping Db layer *)

open Lwt.Infix

(** List all predicates *)
let list_predicates store =
  Db.list_predicates store
  >>= fun predicates_tuples ->
  let predicates = List.map (fun (name, arity) ->
    make_predicate name arity
  ) predicates_tuples in
  Lwt.return predicates

(** List predicates with sample facts *)
let list_predicates_with_samples ~samples store =
  Db.list_predicates_with_samples ~samples store
  >>= fun predicates_tuples ->
  let predicates = List.map (fun (name, arity, sample_facts) ->
    make_predicate ~samples:sample_facts name arity
  ) predicates_tuples in
  Lwt.return predicates

(** Query facts for a predicate *)
let query_predicate ~limit store predicate_name =
  Db.query_predicate ~limit store predicate_name
  >>= fun facts_tuples ->
  let facts = List.map (fun args ->
    make_fact predicate_name args
  ) facts_tuples in
  Lwt.return facts

(** Check if predicate exists *)
let predicate_exists store predicate_name =
  Db.predicate_exists store predicate_name

(** Execute query *)
let execute_query store query =
  Db.execute_query store query
  >>= fun result ->
  Lwt.return (of_query_engine_result result)

(** Execute query with streaming *)
let execute_query_streaming store query ~offset ~limit =
  Db.execute_query_streaming store query ~offset ~limit
  >>= fun result ->
  Lwt.return (of_query_engine_result result)
