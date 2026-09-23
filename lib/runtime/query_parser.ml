(** Query_parser: parse the BeingDB core query language into a structured
    AST ({!Query_ast}) rather than interpreting text at execution time.
    Clause-level parsing (predicate patterns, comparisons, between) is
    shared with the expressive query language via {!Clause_parser}.

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

type query = Query_ast.query = { clauses : Query_ast.clause list; variables : string list }

let parse_query s =
  let s = String.trim s in
  let s = if String.ends_with ~suffix:"." s then String.sub s 0 (String.length s - 1) else s in
  match Lexer.tokenize s with
  | Error _ -> None
  | Ok tokens -> (
      if tokens = [] then None
      else
        let groups = Clause_parser.split_top_level_commas tokens in
        let results = List.map Clause_parser.parse_clause_tokens groups in
        if List.exists Result.is_error results then None
        else
          let clauses = List.map (function Ok c -> c | Error _ -> assert false) results in
          let variables = Query_ast.extract_variables clauses in
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
        let groups = Clause_parser.split_top_level_commas tokens in
        let rec collect = function
          | [] -> Ok []
          | g :: rest -> (
              match Clause_parser.parse_clause_tokens g with
              | Ok c -> ( match collect rest with Ok cs -> Ok (c :: cs) | Error _ as e -> e)
              | Error e -> Error e)
        in
        match collect groups with
        | Error e -> Error e
        | Ok clauses -> Ok { clauses; variables = Query_ast.extract_variables clauses })


