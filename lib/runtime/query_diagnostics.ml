(** Query_diagnostics: deterministic, data-aware diagnostics for a
    candidate DSL query, plus the repairs that BeingDB can prove.

    Validation ({!Dsl_lower}) decides whether a query is well formed.
    Diagnostics go further, using the compiled facts and the predicate
    declarations, and only report what BeingDB can establish exactly:

    - [unknown_constant]: an atom that occurs in no fact of any predicate.
    - [constant_not_at_position]: a literal that occurs in no fact of
      this predicate at this argument position (evidence lists where it
      does occur). A clause like that can never match.
    - [disjoint_join]: a variable shared by two positive patterns whose
      positions hold no common value, so the join is always empty.
    - [contradictory_negation]: a [not] block that only repeats positive
      clauses, so it always fails.
    - [singleton_variable]: a named variable used once and neither
      projected nor ordered on; it acts exactly like [_].
    - [role_name_mismatch]: a variable named after the declared role of
      a different argument position of the same predicate.

    Severity ["error"] means the query as written provably returns no
    rows (for a clause in optional/alternative/negated scope the clause
    alone is affected, so it is reported as ["warning"]). Diagnostics
    never change [valid]; that remains {!Dsl_lower}'s decision.

    A [repair] is attached only when BeingDB can prove it:

    - [swap_arguments]: a positive pattern whose literals do not occur at
      their positions, but all occur after swapping exactly one pair of
      positions (and no other single swap works).
    - [replace_variable]: a positive singleton variable whose name, in
      snake_case, is an atom that occurs at exactly that position
      ([soundtrack_by(CulturalQuarter, P)] -> [cultural_quarter]).

    {!apply_repairs} rewrites only the affected lines of the source text
    and re-parses the result to check it is exactly the intended query;
    if not, no repaired query is offered. *)

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

let severity_name = function Error -> "error" | Warning -> "warning" | Info -> "info"

let scope_name = function
  | Positive -> "positive"
  | Optional_scope -> "optional"
  | Alternative_scope -> "alternative"
  | Negated_scope -> "negated"

(* ---- Rendering DSL source text ---- *)

let quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter (fun c -> if c = '"' || c = '\\' then Buffer.add_char b '\\'; Buffer.add_char b c) s;
  Buffer.add_char b '"';
  Buffer.contents b

(** A literal in DSL source syntax (round-trips through {!Lexer}). *)
let dsl_literal (v : Value.t) =
  match v with
  | Atom s -> s
  | String s -> quote s
  | Lang_string { value; language } -> quote value ^ "@" ^ language
  | Integer _ | Decimal _ | Boolean _ -> Value.canonical_string v
  | Year _ | Year_month _ | Date _ | Instant _ -> "@" ^ Value.canonical_string v
  | Uri s -> "<" ^ s ^ ">"

let dsl_term = function Query_ast.Variable v -> v | Wildcard -> "_" | Literal v -> dsl_literal v
let dsl_pattern predicate arguments = Printf.sprintf "%s(%s)" predicate (String.concat ", " (List.map dsl_term arguments))

let repair_to_json = function
  | Swap_arguments { predicate; line; positions = i, j } ->
      `Assoc
        [
          ("kind", `String "swap_arguments");
          ("predicate", `String predicate);
          ("line", `Int line);
          ("positions", `List [ `Int i; `Int j ]);
        ]
  | Replace_variable { predicate; line; argument_position; variable; value } ->
      `Assoc
        [
          ("kind", `String "replace_variable");
          ("predicate", `String predicate);
          ("line", `Int line);
          ("argumentPosition", `Int argument_position);
          ("variable", `String variable);
          ("value", Value.to_json value);
        ]

let to_json (d : t) : Yojson.Safe.t =
  let opt name f = function Some x -> [ (name, f x) ] | None -> [] in
  `Assoc
    ([ ("code", `String d.code); ("severity", `String (severity_name d.severity)); ("message", `String d.message) ]
    @ opt "line" (fun l -> `Int l) d.line
    @ opt "predicate" (fun p -> `String p) d.predicate
    @ opt "argumentPosition" (fun i -> `Int i) d.argument_position
    @ opt "variable" (fun v -> `String v) d.variable
    @ opt "value" Value.to_json d.value
    @ opt "scope" (fun s -> `String (scope_name s)) d.scope
    @ (if d.evidence = [] then [] else [ ("evidence", `Assoc d.evidence) ])
    @ opt "repair" repair_to_json d.repair)

let make ?line ?predicate ?argument_position ?variable ?value ?scope ?(evidence = []) ?repair ~severity code message =
  { code; severity; message; line; predicate; argument_position; variable; value; scope; evidence; repair }

(* ---- Query structure ---- *)

type site = { predicate : string; arguments : Query_ast.term list; line : int; scope : scope }

let rec sites scope clauses =
  List.concat_map
    (fun (c : Surface_ast.surface_clause) ->
      match c with
      | Pattern { predicate; arguments; line; _ } -> [ { predicate; arguments; line; scope } ]
      | Compare _ | Between _ -> []
      | Optional inner -> sites (if scope = Positive then Optional_scope else scope) inner
      | Alternatives branches -> List.concat_map (sites (if scope = Positive then Alternative_scope else scope)) branches
      | Negation inner -> sites Negated_scope inner)
    clauses

let rec variable_occurrences clauses =
  List.concat_map
    (fun (c : Surface_ast.surface_clause) ->
      let vars = List.filter_map (function Query_ast.Variable v -> Some v | _ -> None) in
      match c with
      | Pattern { arguments; _ } -> vars arguments
      | Compare { left; right; _ } -> vars [ left; right ]
      | Between { value; lower; upper; _ } -> vars [ value; lower; upper ]
      | Optional inner | Negation inner -> variable_occurrences inner
      | Alternatives branches -> List.concat_map variable_occurrences branches)
    clauses

(** [CulturalQuarter] -> [cultural_quarter], [BBC] -> [bbc],
    [Elsa_Stansfield] -> [elsa_stansfield]. *)
let snake_case v =
  let b = Buffer.create (String.length v + 4) in
  String.iteri
    (fun i c ->
      let is_upper = c >= 'A' && c <= 'Z' in
      if is_upper && i > 0 then (
        let p = v.[i - 1] in
        if (p >= 'a' && p <= 'z') || (p >= '0' && p <= '9') then Buffer.add_char b '_');
      Buffer.add_char b (Char.lowercase_ascii c))
    v;
  Buffer.contents b

(** Role-style comparison key: case-insensitive, trailing digits dropped
    ([Person2] -> [person]). *)
let role_key s =
  let n = ref (String.length s) in
  while !n > 0 && s.[!n - 1] >= '0' && s.[!n - 1] <= '9' do decr n done;
  String.lowercase_ascii (String.sub s 0 !n)

let value_key (v : Value.t) = Value.type_name v ^ ":" ^ Value.canonical_string v
let lit_list l = `List (List.map (fun i -> `Int i) l)

module Make (Store : Runtime_store.S) = struct
  let ( let* ) = Lwt.bind

  type ctx = {
    store : Store.t;
    env : Query_environment.t;
    occurs_cache : (string * int * string, bool) Hashtbl.t;
    values_cache : (string * int, (string, unit) Hashtbl.t) Hashtbl.t;
  }

  let occurs ctx predicate i v =
    let key = (predicate, i, value_key v) in
    match Hashtbl.find_opt ctx.occurs_cache key with
    | Some b -> Lwt.return b
    | None ->
        let* facts = Store.equality_lookup ctx.store predicate i v in
        let b = facts <> [] in
        Hashtbl.replace ctx.occurs_cache key b;
        Lwt.return b

  let positions_where ctx predicate arity v =
    Lwt_list.filter_s (fun i -> occurs ctx predicate i v) (List.init arity Fun.id)

  (* Every (predicate, position) holding the atom, in environment order. *)
  let atom_sites ctx v =
    Lwt_list.fold_left_s
      (fun acc (p : Query_environment.predicate_signature) ->
        Lwt_list.fold_left_s
          (fun acc (a : Query_environment.argument_signature) ->
            if not (List.mem "atom" a.types) then Lwt.return acc
            else
              let* hit = occurs ctx p.name a.position v in
              Lwt.return (if hit then (p.name, a.position) :: acc else acc))
          acc p.arguments)
      [] ctx.env.predicates
    |> Lwt.map (fun l -> List.sort compare l)

  let position_values ctx predicate i =
    match Hashtbl.find_opt ctx.values_cache (predicate, i) with
    | Some t -> Lwt.return t
    | None ->
        let* facts = Store.query_all ctx.store predicate in
        let t = Hashtbl.create (List.length facts) in
        List.iter (fun (f : Fact.t) -> match List.nth_opt f.arguments i with Some v -> Hashtbl.replace t (value_key v) () | None -> ()) facts;
        Hashtbl.replace ctx.values_cache (predicate, i) t;
        Lwt.return t

  let signature ctx (s : site) =
    match Query_environment.find ctx.env s.predicate with
    | Some p when p.arity = List.length s.arguments -> Some p
    | _ -> None

  let role (p : Query_environment.predicate_signature) i = Option.bind (List.nth_opt p.arguments i) (fun a -> a.role)
  let role_evidence p i = match role p i with Some r -> [ ("declaredRole", `String r) ] | None -> []

  let swap l i j = List.mapi (fun k x -> if k = i then List.nth l j else if k = j then List.nth l i else x) l

  let literals args = List.filter_map (fun x -> x) (List.mapi (fun i t -> match t with Query_ast.Literal v -> Some (i, v) | _ -> None) args)

  (* The unique pair of positions whose swap grounds every literal of a
     pattern in which some literal is currently ungrounded. *)
  let proven_swap ctx (p : Query_environment.predicate_signature) args =
    let lits = literals args in
    let pairs = List.concat_map (fun i -> List.filter_map (fun j -> if j > i then Some (i, j) else None) (List.init p.arity Fun.id)) (List.init p.arity Fun.id) in
    let* ok_pairs =
      Lwt_list.filter_s
        (fun (i, j) ->
          let swapped = swap args i j in
          Lwt_list.for_all_s (fun (k, v) -> occurs ctx p.name k v) (literals swapped)
          |> Lwt.map (fun all -> all && List.exists (fun (k, _) -> k = i || k = j) lits))
        pairs
    in
    Lwt.return (match ok_pairs with [ pair ] -> Some pair | _ -> None)

  let grounding_diagnostics ctx (s : site) =
    match signature ctx s with
    | None -> Lwt.return []
    | Some p ->
        let* ungrounded =
          Lwt_list.filter_s (fun (i, v) -> Lwt.map not (occurs ctx p.name i v)) (literals s.arguments)
        in
        if ungrounded = [] then Lwt.return []
        else
          let* swap_repair =
            if s.scope = Positive then
              Lwt.map (Option.map (fun pr -> Swap_arguments { predicate = p.name; line = s.line; positions = pr })) (proven_swap ctx p s.arguments)
            else Lwt.return None
          in
          let severity = if s.scope = Positive then Error else Warning in
          Lwt_list.mapi_s
            (fun n (i, (v : Value.t)) ->
              let* same = positions_where ctx p.name p.arity v in
              let* elsewhere = match v with Atom _ -> Lwt.map Option.some (atom_sites ctx v) | _ -> Lwt.return None in
              let repair = if n = 0 then swap_repair else None in
              let lit = dsl_literal v in
              match elsewhere with
              | Some [] ->
                  Lwt.return
                    (make ~severity ~line:s.line ~predicate:p.name ~argument_position:i ~value:v ~scope:s.scope
                       ~evidence:(role_evidence p i) ?repair "unknown_constant"
                       (Printf.sprintf "'%s' does not occur in any fact, so %s(...) cannot match it." lit p.name))
              | _ ->
                  let sites_json =
                    match elsewhere with
                    | Some l ->
                        let others = List.filter (fun (q, _) -> q <> p.name) l in
                        [
                          ( "occursIn",
                            `List
                              (List.map
                                 (fun (q, k) -> `Assoc [ ("predicate", `String q); ("argumentPosition", `Int k) ])
                                 (List.filteri (fun idx _ -> idx < 10) others)) );
                          ("occursInCount", `Int (List.length others));
                        ]
                    | None -> []
                  in
                  let where =
                    match same with
                    | [] -> Printf.sprintf "'%s' never occurs in %s." lit p.name
                    | l ->
                        Printf.sprintf "'%s' occurs in %s only at argument %s." lit p.name
                          (String.concat ", " (List.map string_of_int l))
                  in
                  Lwt.return
                    (make ~severity ~line:s.line ~predicate:p.name ~argument_position:i ~value:v ~scope:s.scope
                       ~evidence:(role_evidence p i @ [ ("occursAtPositions", lit_list same) ] @ sites_json)
                       ?repair "constant_not_at_position"
                       (Printf.sprintf "No %s fact has '%s' as argument %d. %s" p.name lit i where)))
            ungrounded

  let singleton_diagnostics ctx (surface : Surface_ast.surface_query) all_sites =
    let occ = variable_occurrences surface.where_ in
    let count v = List.length (List.filter (( = ) v) occ) in
    let excluded v = List.mem v surface.projection.variables || List.exists (fun (o : Core_query.order_item) -> o.variable = v) surface.order_by in
    Lwt_list.fold_left_s
      (fun acc (s : site) ->
        match signature ctx s with
        | None -> Lwt.return acc
        | Some p ->
            Lwt_list.fold_left_s
              (fun acc (i, t) ->
                match t with
                | Query_ast.Variable v when count v = 1 && not (excluded v) ->
                    let atom = Value.Atom (snake_case v) in
                    let* grounded =
                      if s.scope = Positive && List.mem "atom" (List.nth p.arguments i).types then occurs ctx p.name i atom
                      else Lwt.return false
                    in
                    let repair =
                      if grounded then Some (Replace_variable { predicate = p.name; line = s.line; argument_position = i; variable = v; value = atom })
                      else None
                    in
                    let hint = if grounded then Printf.sprintf " '%s' occurs at that position." (snake_case v) else "" in
                    Lwt.return
                      (make ~severity:Warning ~line:s.line ~predicate:p.name ~argument_position:i ~variable:v ~scope:s.scope
                         ~evidence:(role_evidence p i) ?repair "singleton_variable"
                         (Printf.sprintf "Variable %s is used only once and is not in 'find', so it matches anything, like _.%s" v hint)
                      :: acc)
                | _ -> Lwt.return acc)
              acc
              (List.mapi (fun i t -> (i, t)) s.arguments))
      [] all_sites
    |> Lwt.map List.rev

  let role_diagnostics ctx all_sites =
    List.concat_map
      (fun (s : site) ->
        match signature ctx s with
        | None -> []
        | Some p ->
            List.concat
              (List.mapi
                 (fun i t ->
                   match (t, role p i) with
                   | Query_ast.Variable v, Some own when role_key v <> role_key own -> (
                       let matches =
                         List.filter (fun k -> k <> i && Option.map role_key (role p k) = Some (role_key v)) (List.init p.arity Fun.id)
                       in
                       match matches with
                       | [ k ] ->
                           [
                             make ~severity:Warning ~line:s.line ~predicate:p.name ~argument_position:i ~variable:v ~scope:s.scope
                               ~evidence:[ ("declaredRole", `String own); ("matchesRoleAt", `Int k); ("matchesRole", `String (Option.get (role p k))) ]
                               "role_name_mismatch"
                               (Printf.sprintf "%s is argument %d of %s, whose declared role is %s; %s is the role of argument %d." v i p.name own
                                  (Option.get (role p k)) k);
                           ]
                       | _ -> [])
                   | _ -> [])
                 s.arguments))
      all_sites

  (* Pairwise value-set disjointness of a variable's positive pattern sites. *)
  let join_diagnostics ctx all_sites =
    let positive = List.filter (fun (s : site) -> s.scope = Positive && signature ctx s <> None) all_sites in
    let var_sites =
      List.concat_map
        (fun (s : site) -> List.concat (List.mapi (fun i t -> match t with Query_ast.Variable v -> [ (v, (s, i)) ] | _ -> []) s.arguments))
        positive
    in
    let vars = List.sort_uniq String.compare (List.map fst var_sites) in
    let numeric (s : site) i =
      match signature ctx s with
      | Some p -> List.exists (fun t -> t = "integer" || t = "decimal") (List.nth p.arguments i).types
      | None -> true
    in
    Lwt_list.fold_left_s
      (fun acc v ->
        let occ = List.filter_map (fun (w, x) -> if w = v then Some x else None) var_sites in
        let pairs = List.concat (List.mapi (fun n a -> List.filteri (fun m _ -> m > n) occ |> List.map (fun b -> (a, b))) occ) in
        let* found =
          Lwt_list.fold_left_s
            (fun found (((s1 : site), i1), ((s2 : site), i2)) ->
              if found <> None || numeric s1 i1 || numeric s2 i2 || (s1.predicate = s2.predicate && i1 = i2) then Lwt.return found
              else
                let* a = position_values ctx s1.predicate i1 in
                let* b = position_values ctx s2.predicate i2 in
                let shared = Hashtbl.fold (fun k () n -> if Hashtbl.mem b k then n + 1 else n) a 0 in
                Lwt.return (if shared = 0 then Some ((s1, i1), (s2, i2)) else None))
            None pairs
        in
        match found with
        | None -> Lwt.return acc
        | Some ((s1, i1), (s2, i2)) ->
            let site_json (s : site) i =
              let p = Option.get (signature ctx s) in
              `Assoc
                ([ ("predicate", `String s.predicate); ("argumentPosition", `Int i); ("line", `Int s.line) ]
                @ match role p i with Some r -> [ ("declaredRole", `String r) ] | None -> [])
            in
            Lwt.return
              (make ~severity:Error ~line:s2.line ~variable:v ~scope:Positive
                 ~evidence:[ ("sites", `List [ site_json s1 i1; site_json s2 i2 ]) ]
                 "disjoint_join"
                 (Printf.sprintf "%s joins %s argument %d with %s argument %d, but those arguments share no value, so the query returns no rows." v
                    s1.predicate i1 s2.predicate i2)
              :: acc))
      [] vars
    |> Lwt.map List.rev

  let negation_diagnostics (surface : Surface_ast.surface_query) =
    let positive =
      List.filter_map (function Surface_ast.Pattern { predicate; arguments; _ } -> Some (predicate, arguments) | _ -> None) surface.where_
    in
    List.filter_map
      (function
        | Surface_ast.Negation inner when inner <> [] ->
            let repeated =
              List.for_all (function Surface_ast.Pattern { predicate; arguments; _ } -> List.mem (predicate, arguments) positive | _ -> false) inner
            in
            if not repeated then None
            else
              let line = match inner with Surface_ast.Pattern { line; _ } :: _ -> Some line | _ -> None in
              Some
                (make ~severity:Error ?line ~scope:Negated_scope "contradictory_negation"
                   "This 'not' block only repeats clauses that must already hold, so it always fails and the query returns no rows.")
        | _ -> None)
      surface.where_

  let diagnose store env (surface : Surface_ast.surface_query) =
    let ctx = { store; env; occurs_cache = Hashtbl.create 64; values_cache = Hashtbl.create 16 } in
    let all_sites = sites Positive surface.where_ in
    let* grounding = Lwt_list.map_s (grounding_diagnostics ctx) all_sites in
    let* singletons = singleton_diagnostics ctx surface all_sites in
    let* joins = join_diagnostics ctx all_sites in
    let all = List.concat grounding @ singletons @ role_diagnostics ctx all_sites @ joins @ negation_diagnostics surface in
    let line_of (d : t) = Option.value d.line ~default:max_int in
    Lwt.return (List.stable_sort (fun a b -> compare (line_of a) (line_of b)) all)
end

(* ---- Applying repairs ---- *)

let repair_line = function Swap_arguments { line; _ } | Replace_variable { line; _ } -> line

let apply_to_terms repair arguments =
  match repair with
  | Swap_arguments { positions = i, j; _ } ->
      List.mapi (fun k x -> if k = i then List.nth arguments j else if k = j then List.nth arguments i else x) arguments
  | Replace_variable { argument_position; value; _ } ->
      List.mapi (fun k x -> if k = argument_position then Query_ast.Literal value else x) arguments

let rec repair_clauses repairs clauses =
  List.map
    (fun (c : Surface_ast.surface_clause) ->
      match c with
      | Pattern ({ line; arguments; _ } as p) ->
          let mine = List.filter (fun r -> repair_line r = line) repairs in
          Surface_ast.Pattern { p with arguments = List.fold_left (fun args r -> apply_to_terms r args) arguments mine }
      | Compare _ | Between _ -> c
      | Optional inner -> Optional (repair_clauses repairs inner)
      | Alternatives branches -> Alternatives (List.map (repair_clauses repairs) branches)
      | Negation inner -> Negation (repair_clauses repairs inner))
    clauses

let rec patterns_by_line clauses =
  List.concat_map
    (fun (c : Surface_ast.surface_clause) ->
      match c with
      | Pattern { predicate; arguments; line; _ } -> [ (line, (predicate, arguments)) ]
      | Compare _ | Between _ -> []
      | Optional inner | Negation inner -> patterns_by_line inner
      | Alternatives branches -> List.concat_map patterns_by_line branches)
    clauses

(** The repaired source text: each repaired pattern's line is re-rendered
    (indentation kept), every other line is untouched. [None] unless the
    result parses back to exactly the repaired query. *)
let apply_repairs text (surface : Surface_ast.surface_query) repairs =
  if repairs = [] then None
  else
    let expected = { surface with where_ = repair_clauses repairs surface.where_ } in
    let lines = patterns_by_line expected.where_ in
    let rewritten =
      String.split_on_char '\n' text
      |> List.mapi (fun i raw ->
             match List.assoc_opt (i + 1) lines with
             | Some (predicate, arguments) when List.exists (fun r -> repair_line r = i + 1) repairs ->
                 let n = ref 0 in
                 while !n < String.length raw && (raw.[!n] = ' ' || raw.[!n] = '\t') do incr n done;
                 String.sub raw 0 !n ^ dsl_pattern predicate arguments
             | _ -> raw)
      |> String.concat "\n"
    in
    match Dsl_parser.parse rewritten with Ok reparsed when reparsed = expected -> Some rewritten | _ -> None

(** Deduplicated repairs carried by the diagnostics, in line order. *)
let repairs diagnostics =
  List.filter_map (fun d -> d.repair) diagnostics |> List.sort_uniq compare |> List.stable_sort (fun a b -> compare (repair_line a) (repair_line b))

(** The full report for a DSL query: validation ([valid], [errors],
    [warnings], exactly as {!Dsl_lower} produces them), [diagnostics],
    [provablyEmpty] and, when BeingDB can prove a repair, [repair] with
    the repaired query text and the repairs applied. Callers append the
    language/environment fields of their transport. *)
module Report (Store : Runtime_store.S) = struct
  module D = Make (Store)

  let ( let* ) = Lwt.bind

  let fields store env text : (string * Yojson.Safe.t) list Lwt.t =
    match Dsl_parser.parse text with
    | Error message ->
        Lwt.return
          [
            ("valid", `Bool false);
            ("errors", `List [ `Assoc [ ("code", `String "syntax_error"); ("message", `String message) ] ]);
            ("warnings", `List []);
            ("diagnostics", `List []);
            ("provablyEmpty", `Bool false);
          ]
    | Ok surface ->
        let lowered = Dsl_lower.lower env surface in
        let* diagnostics = D.diagnose store env surface in
        let rs = repairs diagnostics in
        let repair =
          match apply_repairs text surface rs with
          | Some query -> [ ("repair", `Assoc [ ("query", `String query); ("applied", `List (List.map repair_to_json rs)) ]) ]
          | None -> []
        in
        Lwt.return
          ([
             ("valid", `Bool (lowered.errors = []));
             ("errors", `List (List.map Validation_error.to_json lowered.errors));
             ("warnings", `List (List.map Validation_error.warning_to_json lowered.warnings));
             ("diagnostics", `List (List.map to_json diagnostics));
             ("provablyEmpty", `Bool (List.exists (fun d -> d.severity = Error) diagnostics));
           ]
          @ repair)
end
