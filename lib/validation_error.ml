(** Validation_error: structured errors and warnings produced while
    lowering a {!Surface_ast.surface_query} (or validating a core-language
    query) against a {!Query_environment}. Each carries enough structure
    to render both a human-readable message and a machine-readable JSON
    shape for the [/query] "validate"/"explain" actions. *)

type t =
  | Syntax_error of { message : string; line : int option }
  | Unknown_predicate of { predicate : string; suggestions : string list; line : int option }
  | Arity_mismatch of { predicate : string; expected : int; received : int; line : int option }
  | Literal_type_mismatch of {
      predicate : string;
      argument_position : int;
      expected_types : string list;
      received_type : string;
      line : int option;
    }
  | Comparison_type_mismatch of { message : string; line : int option }
  | Unbound_projection of { variable : string }
  | Unbound_order_variable of { variable : string }
  | Unsafe_negation of { variables : string list }
  | Invalid_optional_scope of { message : string }
  | Invalid_alternative_scope of { message : string }

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

let line = function
  | Syntax_error { line; _ }
  | Unknown_predicate { line; _ }
  | Arity_mismatch { line; _ }
  | Literal_type_mismatch { line; _ }
  | Comparison_type_mismatch { line; _ } ->
      line
  | Unbound_projection _ | Unbound_order_variable _ | Unsafe_negation _ | Invalid_optional_scope _ | Invalid_alternative_scope _ -> None

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

let to_json (e : t) : Yojson.Safe.t =
  let base = [ ("code", `String (code e)); ("message", `String (message e)) ] in
  let line_field = match line e with Some l -> [ ("line", `Int l) ] | None -> [] in
  let extra =
    match e with
    | Unknown_predicate { predicate; suggestions; _ } ->
        [ ("predicate", `String predicate); ("suggestions", `List (List.map (fun s -> `String s) suggestions)) ]
    | Arity_mismatch { predicate; expected; received; _ } ->
        [ ("predicate", `String predicate); ("expected", `Int expected); ("received", `Int received) ]
    | Literal_type_mismatch { predicate; argument_position; expected_types; received_type; _ } ->
        [
          ("predicate", `String predicate);
          ("argument_position", `Int argument_position);
          ("expected_types", `List (List.map (fun s -> `String s) expected_types));
          ("received_type", `String received_type);
        ]
    | Unbound_projection { variable } | Unbound_order_variable { variable } -> [ ("variable", `String variable) ]
    | Unsafe_negation { variables } -> [ ("variables", `List (List.map (fun s -> `String s) variables)) ]
    | Syntax_error _ | Comparison_type_mismatch _ | Invalid_optional_scope _ | Invalid_alternative_scope _ -> []
  in
  `Assoc (base @ line_field @ extra)

let warning_to_json (w : warning) : Yojson.Safe.t =
  let line_field = match w.line with Some l -> [ ("line", `Int l) ] | None -> [] in
  `Assoc ([ ("code", `String w.code); ("message", `String w.message) ] @ line_field)
