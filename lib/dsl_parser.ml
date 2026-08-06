(** Dsl_parser: parses the expressive query language's line-oriented
    textual syntax into a {!Surface_ast.surface_query}.

    Surface syntax:
    {v
      find [distinct] Var, Var, ...
      where
        predicate(Args...)
        Term (= | != | < | <= | > | >=) Term
        Term between Term and Term
        optional
          <clause>*
        either
          <clause>*
        or
          <clause>*
        not
          <clause>*
      order by Var [ascending|descending], ...
      limit N
      offset N
    v}

    Leaf clauses (predicate patterns, comparisons, between) reuse
    {!Clause_parser} so the expressive language accepts exactly the same
    literal syntax as the core language. *)

let ( let* ) r f = match r with Ok x -> f x | Error _ as e -> e

let starts_with ~prefix s = String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

(** Non-blank, non-comment lines, each tagged with its 1-based source
    line number and trimmed of surrounding whitespace. *)
let significant_lines text =
  String.split_on_char '\n' text
  |> List.mapi (fun i line -> (i + 1, String.trim line))
  |> List.filter (fun (_, line) -> line <> "" && not (starts_with ~prefix:"%" line) && not (starts_with ~prefix:"#" line))

let is_tail_keyword line =
  line = "order by" || starts_with ~prefix:"order by " line || line = "limit" || starts_with ~prefix:"limit " line
  || line = "offset" || starts_with ~prefix:"offset " line

let is_group_boundary (_, line) =
  is_tail_keyword line || line = "optional" || line = "either" || line = "or" || line = "not"

let take_while pred lines =
  let rec go acc = function l :: rest when pred l -> go (l :: acc) rest | rest -> (List.rev acc, rest) in
  go [] lines

let take_group lines = take_while (fun l -> not (is_group_boundary l)) lines

let parse_clause_line (line_no, text) =
  let* tokens = match Lexer.tokenize text with Ok t -> Ok t | Error e -> Error (Printf.sprintf "Line %d: %s" line_no e) in
  let* clause =
    match Clause_parser.parse_clause_tokens tokens with
    | Ok c -> Ok c
    | Error e -> Error (Printf.sprintf "Line %d: %s" line_no e)
  in
  match clause with
  | Query_ast.Pattern { predicate; arguments } -> Ok (Surface_ast.Pattern { predicate; arguments; line = line_no })
  | Query_ast.Compare { left; operator; right } -> Ok (Surface_ast.Compare { left; operator; right; line = line_no })
  | Query_ast.Between { value; lower; upper } -> Ok (Surface_ast.Between { value; lower; upper; line = line_no })
  | Query_ast.Optional _ | Query_ast.Alternatives _ | Query_ast.Not_exists _ ->
      Error (Printf.sprintf "Line %d: unexpected clause shape" line_no)

(** Parse a (possibly nested) run of clause lines, stopping at the first
    line belonging to an enclosing scope's next section (a sibling
    [optional]/[either]/[or]/[not], or a trailing [order by]/[limit]/
    [offset]). Returns the parsed clauses together with the unconsumed
    remainder. *)
let rec parse_clauses lines =
  match lines with
  | [] -> Ok ([], [])
  | (_, line) :: _ when is_tail_keyword line -> Ok ([], lines)
  | (_, "optional") :: rest ->
      let group_lines, remaining = take_group rest in
      let* inner, _ = parse_clauses group_lines in
      let* rest_clauses, final_remaining = parse_clauses remaining in
      Ok (Surface_ast.Optional inner :: rest_clauses, final_remaining)
  | (_, "not") :: rest ->
      let group_lines, remaining = take_group rest in
      let* inner, _ = parse_clauses group_lines in
      let* rest_clauses, final_remaining = parse_clauses remaining in
      Ok (Surface_ast.Negation inner :: rest_clauses, final_remaining)
  | (line_no, "either") :: rest -> (
      let branch1_lines, after1 = take_group rest in
      if branch1_lines = [] then Error (Printf.sprintf "Line %d: 'either' block must not be empty" line_no)
      else
        let* branch1, _ = parse_clauses branch1_lines in
        let rec collect_or lines acc =
          match lines with
          | (or_line_no, "or") :: rest2 ->
              let branch_lines, remaining2 = take_group rest2 in
              if branch_lines = [] then Error (Printf.sprintf "Line %d: 'or' block must not be empty" or_line_no)
              else
                let* branch, _ = parse_clauses branch_lines in
                collect_or remaining2 (branch :: acc)
          | _ -> Ok (List.rev acc, lines)
        in
        let* or_branches, remaining = collect_or after1 [] in
        if or_branches = [] then Error (Printf.sprintf "Line %d: 'either' must be followed by at least one 'or' branch" line_no)
        else
          let* rest_clauses, final_remaining = parse_clauses remaining in
          Ok (Surface_ast.Alternatives (branch1 :: or_branches) :: rest_clauses, final_remaining))
  | (line_no, "or") :: _ -> Error (Printf.sprintf "Line %d: 'or' without a preceding 'either'" line_no)
  | line :: rest ->
      let* clause = parse_clause_line line in
      let* rest_clauses, final_remaining = parse_clauses rest in
      Ok (clause :: rest_clauses, final_remaining)

let parse_find text =
  let text = String.trim text in
  let distinct, rest =
    if starts_with ~prefix:"distinct" text && (String.length text = 8 || text.[8] = ' ') then
      (true, String.trim (String.sub text 8 (String.length text - 8)))
    else (false, text)
  in
  if rest = "" then Error "'find' requires at least one projected variable"
  else
    let names = String.split_on_char ',' rest |> List.map String.trim |> List.filter (( <> ) "") in
    if names = [] then Error "'find' requires at least one projected variable"
    else if List.exists (fun n -> n = "" || Char.uppercase_ascii n.[0] <> n.[0]) names then
      Error "'find' variables must start with an uppercase letter"
    else Ok { Surface_ast.variables = names; distinct }

let parse_order_item line_no text =
  match String.split_on_char ' ' (String.trim text) |> List.filter (( <> ) "") with
  | [ var ] -> Ok { Core_query.variable = var; direction = Core_query.Ascending }
  | [ var; dir ] -> (
      match String.lowercase_ascii dir with
      | "ascending" | "asc" -> Ok { Core_query.variable = var; direction = Core_query.Ascending }
      | "descending" | "desc" -> Ok { Core_query.variable = var; direction = Core_query.Descending }
      | _ -> Error (Printf.sprintf "Line %d: invalid order direction: %s" line_no dir))
  | _ -> Error (Printf.sprintf "Line %d: invalid order-by item: %s" line_no text)

let drop_prefix prefix s = String.trim (String.sub s (String.length prefix) (String.length s - String.length prefix))

let rec parse_tail lines order_acc limit_acc offset_acc =
  match lines with
  | [] -> Ok (List.rev order_acc, limit_acc, offset_acc)
  | (line_no, line) :: rest when line = "order by" || starts_with ~prefix:"order by " line ->
      let trailing = if line = "order by" then "" else drop_prefix "order by " line in
      let item_lines, remaining = take_while (fun (_, l) -> not (is_tail_keyword l)) rest in
      let raw = (if trailing = "" then [] else [ (line_no, trailing) ]) @ item_lines in
      let flattened =
        List.concat_map (fun (ln, text) -> String.split_on_char ',' text |> List.map (fun p -> (ln, String.trim p))) raw
        |> List.filter (fun (_, p) -> p <> "")
      in
      let* items = List.fold_left (fun acc (ln, p) -> let* items = acc in let* item = parse_order_item ln p in Ok (item :: items)) (Ok []) flattened in
      parse_tail remaining (List.rev_append items order_acc) limit_acc offset_acc
  | (line_no, line) :: rest when line = "limit" || starts_with ~prefix:"limit " line -> (
      let v = if line = "limit" then "" else drop_prefix "limit " line in
      match int_of_string_opt v with
      | Some n when n > 0 -> parse_tail rest order_acc (Some n) offset_acc
      | _ -> Error (Printf.sprintf "Line %d: invalid 'limit' value: %s" line_no v))
  | (line_no, line) :: rest when line = "offset" || starts_with ~prefix:"offset " line -> (
      let v = if line = "offset" then "" else drop_prefix "offset " line in
      match int_of_string_opt v with
      | Some n when n >= 0 -> parse_tail rest order_acc limit_acc (Some n)
      | _ -> Error (Printf.sprintf "Line %d: invalid 'offset' value: %s" line_no v))
  | (line_no, line) :: _ -> Error (Printf.sprintf "Line %d: unexpected content: %s" line_no line)

(** Parse the full expressive-language query text. *)
let parse text =
  let lines = significant_lines text in
  match lines with
  | [] -> Error "Empty query"
  | (_, first) :: rest when first = "find" || starts_with ~prefix:"find " first ->
      let find_text = if first = "find" then "" else drop_prefix "find " first in
      let* projection = parse_find find_text in
      (match rest with
      | (_, "where") :: after_where ->
          let* where_, tail = parse_clauses after_where in
          let* order_by, limit, offset = parse_tail tail [] None None in
          Ok { Surface_ast.projection; where_; order_by; limit; offset }
      | (line_no, _) :: _ -> Error (Printf.sprintf "Line %d: expected 'where' after 'find ...'" line_no)
      | [] -> Error "Expected 'where' after 'find ...'")
  | (line_no, _) :: _ -> Error (Printf.sprintf "Line %d: expected query to start with 'find ...'" line_no)
