(** Validation_error: structured errors and warnings produced while
    lowering a {!Surface_ast.surface_query} (or validating a core-language
    query) against a {!Query_environment}. Each carries enough structure
    to render both a human-readable message and a machine-readable JSON
    shape for the [/query] "validate"/"explain" actions.

    JSON field names follow camelCase (matching the rest of the
    normalized [/query] response envelope: [environmentFingerprint],
    [languageVersion], etc.); the [code] *value* itself is a stable
    snake_case string (e.g. ["comparison_type_mismatch"]). *)

type t =
  | Syntax_error of { message : string; line : int option; column : int option }
  | Unknown_predicate of { predicate : string; suggestions : string list; line : int option; column : int option }
  | Arity_mismatch of { predicate : string; expected : int; received : int; line : int option; column : int option }
  | Literal_type_mismatch of {
      predicate : string;
      argument_position : int;
      expected_types : string list;
      received_type : string;
      line : int option;
      column : int option;
    }
  | Comparison_type_mismatch of {
      left_type : string;
      right_type : string;
      message : string;
      suggestion : string option;
      line : int option;
      column : int option;
    }
  | Unbound_projection of { variable : string }
  | Unbound_order_variable of { variable : string }
  | Unsafe_negation of { variables : string list }
  | Invalid_optional_scope of { message : string }
  | Invalid_alternative_scope of { message : string }
  | Disconnected_query of { groups : string list list; message : string }
      (** The query's positive patterns form more than one connected
          component -- executing it as written would compute an
          unconstrained Cartesian product. [groups] lists each
          component's clauses (rendered via {!Query_ast.clause_to_string}). *)

type warning = { code : string; message : string; line : int option }

let code = function
  | Syntax_error _ -> "syntax_error"
  | Unknown_predicate _ -> "unknown_predicate"
  | Arity_mismatch _ -> "arity_mismatch"
  | Literal_type_mismatch _ -> "literal_type_mismatch"
  | Comparison_type_mismatch _ -> "comparison_type_mismatch"
  | Unbound_projection _ -> "unbound_projection"
  | Unbound_order_variable _ -> "unbound_order_variable"
  | Unsafe_negation _ -> "unsafe_negation"
  | Invalid_optional_scope _ -> "invalid_optional_scope"
  | Invalid_alternative_scope _ -> "invalid_alternative_scope"
  | Disconnected_query _ -> "disconnected_query"

let line = function
  | Syntax_error { line; _ }
  | Unknown_predicate { line; _ }
  | Arity_mismatch { line; _ }
  | Literal_type_mismatch { line; _ }
  | Comparison_type_mismatch { line; _ } ->
      line
  | Unbound_projection _ | Unbound_order_variable _ | Unsafe_negation _ | Invalid_optional_scope _ | Invalid_alternative_scope _
  | Disconnected_query _ ->
      None

let column = function
  | Syntax_error { column; _ }
  | Unknown_predicate { column; _ }
  | Arity_mismatch { column; _ }
  | Literal_type_mismatch { column; _ }
  | Comparison_type_mismatch { column; _ } ->
      column
  | Unbound_projection _ | Unbound_order_variable _ | Unsafe_negation _ | Invalid_optional_scope _ | Invalid_alternative_scope _
  | Disconnected_query _ ->
      None

let message = function
  | Syntax_error { message; _ } -> message
  | Unknown_predicate { predicate; suggestions; _ } ->
      if suggestions = [] then Printf.sprintf "Unknown predicate '%s'" predicate
      else Printf.sprintf "Unknown predicate '%s'; did you mean: %s?" predicate (String.concat ", " suggestions)
  | Arity_mismatch { predicate; expected; received; _ } ->
      Printf.sprintf "Predicate '%s' expects %d argument(s), got %d" predicate expected received
  | Literal_type_mismatch { predicate; argument_position; expected_types; received_type; _ } ->
      Printf.sprintf "Predicate '%s' argument %d expects type in {%s}, got %s" predicate argument_position
        (String.concat ", " expected_types) received_type
  | Comparison_type_mismatch { message; _ } -> message
  | Unbound_projection { variable } -> Printf.sprintf "'find' projects unbound variable %s" variable
  | Unbound_order_variable { variable } -> Printf.sprintf "'order by' references unbound variable %s" variable
  | Unsafe_negation { variables } ->
      Printf.sprintf "'not' block uses variable(s) not bound outside it: %s" (String.concat ", " variables)
  | Invalid_optional_scope { message } -> message
  | Invalid_alternative_scope { message } -> message
  | Disconnected_query { message; _ } -> message

let to_json (e : t) : Yojson.Safe.t =
  let base = [ ("code", `String (code e)); ("message", `String (message e)) ] in
  let line_field = match line e with Some l -> [ ("line", `Int l) ] | None -> [] in
  let column_field = match column e with Some c -> [ ("column", `Int c) ] | None -> [] in
  let extra =
    match e with
    | Unknown_predicate { predicate; suggestions; _ } ->
        [ ("predicate", `String predicate); ("suggestions", `List (List.map (fun s -> `String s) suggestions)) ]
    | Arity_mismatch { predicate; expected; received; _ } ->
        [ ("predicate", `String predicate); ("expected", `Int expected); ("received", `Int received) ]
    | Literal_type_mismatch { predicate; argument_position; expected_types; received_type; _ } ->
        [
          ("predicate", `String predicate);
          ("argumentPosition", `Int argument_position);
          ("expectedTypes", `List (List.map (fun s -> `String s) expected_types));
          ("receivedType", `String received_type);
        ]
    | Comparison_type_mismatch { left_type; right_type; suggestion; _ } ->
        [ ("leftType", `String left_type); ("rightType", `String right_type) ]
        @ (match suggestion with Some s -> [ ("suggestion", `String s) ] | None -> [])
    | Unbound_projection { variable } | Unbound_order_variable { variable } -> [ ("variable", `String variable) ]
    | Unsafe_negation { variables } -> [ ("variables", `List (List.map (fun s -> `String s) variables)) ]
    | Disconnected_query { groups; _ } ->
        [ ("groups", `List (List.map (fun g -> `List (List.map (fun s -> `String s) g)) groups)) ]
    | Syntax_error _ | Invalid_optional_scope _ | Invalid_alternative_scope _ -> []
  in
  `Assoc (base @ line_field @ column_field @ extra)

let warning_to_json (w : warning) : Yojson.Safe.t =
  let line_field = match w.line with Some l -> [ ("line", `Int l) ] | None -> [] in
  `Assoc ([ ("code", `String w.code); ("message", `String w.message) ] @ line_field)

