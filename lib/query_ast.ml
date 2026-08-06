(** Query AST: structured representation produced by the query parser.
    Comparisons are represented structurally rather than as free text so
    the planner and executor can reason about them (choose indexes,
    perform type-aware comparisons) instead of interpreting text at
    execution time. *)

(** A term in a query clause: either a variable, a wildcard, or a typed
    literal value. *)
type term =
  | Variable of string
  | Wildcard
  | Literal of Value.t

type comparison_operator = Eq | Ne | Lt | Le | Gt | Ge

let string_of_operator = function
  | Eq -> "="
  | Ne -> "!="
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="

(** Flip an operator for the case [literal OP variable] so it can be
    treated uniformly as [variable OP' literal]. *)
let flip_operator = function
  | Eq -> Eq
  | Ne -> Ne
  | Lt -> Gt
  | Le -> Ge
  | Gt -> Lt
  | Ge -> Le

type clause =
  | Pattern of { predicate : string; arguments : term list }
  | Compare of { left : term; operator : comparison_operator; right : term }
  | Between of { value : term; lower : term; upper : term }
  | Optional of clause list
      (** A group whose absence of a match does not reject the outer
          solution; matching bindings are added when it does match
          (left-join semantics). *)
  | Alternatives of clause list list
      (** A set of branches, each a conjunctive group; the overall result
          is the union of each branch's matches. *)
  | Not_exists of clause list
      (** Negation-as-failure: succeeds (without adding bindings) only
          when the group matches zero facts for the current bindings.
          Every variable referenced inside must already be bound by an
          earlier clause -- this is checked at lowering time, not here. *)

type query = { clauses : clause list; variables : string list }

let term_to_string = function
  | Variable v -> v
  | Wildcard -> "_"
  | Literal v -> Value.canonical_string v

let rec clause_to_string = function
  | Pattern { predicate; arguments } ->
      Printf.sprintf "%s(%s)" predicate
        (String.concat ", " (List.map term_to_string arguments))
  | Compare { left; operator; right } ->
      Printf.sprintf "%s %s %s" (term_to_string left) (string_of_operator operator)
        (term_to_string right)
  | Between { value; lower; upper } ->
      Printf.sprintf "%s between %s and %s" (term_to_string value)
        (term_to_string lower) (term_to_string upper)
  | Optional group -> Printf.sprintf "optional { %s }" (group_to_string group)
  | Alternatives branches ->
      Printf.sprintf "either %s"
        (String.concat " or " (List.map (fun g -> Printf.sprintf "{ %s }" (group_to_string g)) branches))
  | Not_exists group -> Printf.sprintf "not { %s }" (group_to_string group)

and group_to_string clauses = String.concat ", " (List.map clause_to_string clauses)

let query_to_string q = group_to_string q.clauses

let variables_of_term = function Variable v -> [ v ] | Wildcard | Literal _ -> []

let rec extract_variables clauses =
  clauses
  |> List.concat_map (function
       | Pattern { arguments; _ } -> List.concat_map variables_of_term arguments
       | Compare { left; right; _ } -> variables_of_term left @ variables_of_term right
       | Between { value; lower; upper } ->
           variables_of_term value @ variables_of_term lower @ variables_of_term upper
       | Optional group -> extract_variables group
       | Not_exists group -> extract_variables group
       | Alternatives branches -> List.concat_map extract_variables branches)
  |> List.sort_uniq String.compare

(** Every [Pattern] anywhere in the clause tree, including inside nested
    [Optional]/[Alternatives]/[Not_exists] groups. Used for structural
    checks (predicate-name validation, Cartesian-product detection) that
    must see through nesting. *)
let rec all_patterns clauses =
  List.concat_map
    (function
      | Pattern { predicate; arguments } -> [ (predicate, arguments) ]
      | Optional group -> all_patterns group
      | Not_exists group -> all_patterns group
      | Alternatives branches -> List.concat_map all_patterns branches
      | Compare _ | Between _ -> [])
    clauses

