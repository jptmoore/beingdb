(** Query_parser: parse the BeingDB query language into a structured AST
    ({!Query_ast}) rather than interpreting text at execution time.

    Query syntax:
    - Variables start with uppercase: Work, Artist, Venue
    - Atoms start with lowercase: tina_keane, she, video
    - Strings in quotes, optionally language-tagged: "text"@en
    - Typed literals: integers, decimals, booleans, @year / @year-month /
      @date / @instant, <uri>
    - Wildcard: _
    - Comparisons: Term (= | != | < | <= | > | >=) Term
    - Range: Term between Term and Term
    - Multiple clauses separated by comma

    Example: "created(tina_keane, Work), birth_year(Work, Y), Y >= 1970"
*)

open Query_ast

type query = Query_ast.query = { clauses : Query_ast.clause list; variables : string list }

let term_of_token = function
  | Lexer.Underscore -> Ok Wildcard
  | Lexer.Ident s when s <> "" && Char.uppercase_ascii s.[0] = s.[0] && s <> "true" && s <> "false" ->
      Ok (Variable s)
  | tok -> ( match Lexer.value_of_token tok with Ok v -> Ok (Literal v) | Error e -> Error e)

(** Split a token list on top-level [Comma] tokens (tracking paren depth
    so commas inside a predicate's argument list are not top-level). *)
let split_top_level_commas tokens =
  let rec go depth acc current = function
    | [] -> List.rev (if current = [] then acc else List.rev current :: acc)
    | Lexer.LParen :: rest -> go (depth + 1) acc (Lexer.LParen :: current) rest
    | Lexer.RParen :: rest -> go (depth - 1) acc (Lexer.RParen :: current) rest
    | Lexer.Comma :: rest when depth = 0 -> go depth (List.rev current :: acc) [] rest
    | tok :: rest -> go depth acc (tok :: current) rest
  in
  go 0 [] [] tokens

let operator_of_string = function
  | "=" -> Some Eq
  | "!=" -> Some Ne
  | "<" -> Some Lt
  | "<=" -> Some Le
  | ">" -> Some Gt
  | ">=" -> Some Ge
  | _ -> None

(** Parse one clause's worth of tokens: a predicate pattern, a comparison,
    or a between-clause. *)
let parse_clause_tokens tokens =
  match tokens with
  | Lexer.Ident predicate :: Lexer.LParen :: rest when List.rev rest <> [] && List.hd (List.rev rest) = Lexer.RParen -> (
      let inner = List.rev (List.tl (List.rev rest)) in
      let groups = if inner = [] then [] else split_top_level_commas inner in
      let rec parse_args = function
        | [] -> Ok []
        | [ tok ] :: rest -> (
            match term_of_token tok with
            | Ok t -> ( match parse_args rest with Ok ts -> Ok (t :: ts) | Error _ as e -> e)
            | Error e -> Error e)
        | _ :: _ -> Error "Invalid argument in predicate pattern"
      in
      match parse_args groups with
      | Ok arguments -> Ok (Pattern { predicate; arguments })
      | Error e -> Error e)
  | [ left_tok; Lexer.Ident "between"; lower_tok; Lexer.Ident "and"; upper_tok ] -> (
      match (term_of_token left_tok, term_of_token lower_tok, term_of_token upper_tok) with
      | Ok value, Ok lower, Ok upper -> Ok (Between { value; lower; upper })
      | Error e, _, _ | _, Error e, _ | _, _, Error e -> Error e)
  | [ left_tok; Lexer.Op op; right_tok ] -> (
      match operator_of_string op with
      | None -> Error (Printf.sprintf "Unknown operator: %s" op)
      | Some operator -> (
          match (term_of_token left_tok, term_of_token right_tok) with
          | Ok left, Ok right -> Ok (Compare { left; operator; right })
          | Error e, _ | _, Error e -> Error e))
  | [] -> Error "Empty clause"
  | _ -> Error "Invalid clause: expected a predicate pattern, comparison, or between-clause"

let parse_query s =
  let s = String.trim s in
  let s = if String.ends_with ~suffix:"." s then String.sub s 0 (String.length s - 1) else s in
  match Lexer.tokenize s with
  | Error _ -> None
  | Ok tokens -> (
      if tokens = [] then None
      else
        let groups = split_top_level_commas tokens in
        let results = List.map parse_clause_tokens groups in
        if List.exists Result.is_error results then None
        else
          let clauses = List.map (function Ok c -> c | Error _ -> assert false) results in
          let variables = extract_variables clauses in
          Some { clauses; variables })

(** Like {!parse_query} but surfaces a parse error message instead of
    discarding it. *)
let parse_query_result s =
  let s = String.trim s in
  let s = if String.ends_with ~suffix:"." s then String.sub s 0 (String.length s - 1) else s in
  match Lexer.tokenize s with
  | Error e -> Error e
  | Ok tokens -> (
      if tokens = [] then Error "Empty query"
      else
        let groups = split_top_level_commas tokens in
        let rec collect = function
          | [] -> Ok []
          | g :: rest -> (
              match parse_clause_tokens g with
              | Ok c -> ( match collect rest with Ok cs -> Ok (c :: cs) | Error _ as e -> e)
              | Error e -> Error e)
        in
        match collect groups with
        | Error e -> Error e
        | Ok clauses -> Ok { clauses; variables = extract_variables clauses })

