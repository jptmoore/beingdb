(** Parse_predicate: parsing of typed predicate facts from source text.

    Facts look like [predicate(arg1, arg2, ...).] where each argument is a
    typed literal (atom, string, language-tagged string, integer, decimal,
    boolean, year, year-month, date, instant, or URI). No variables or
    wildcards are permitted in facts.
*)

(** Parse one line of source. [None] means the line is blank, a comment,
    or otherwise not fact-shaped and should be silently skipped. [Some
    (Error msg)] means the line looked like a fact but failed to parse
    (e.g. an invalid literal), with a human-readable reason. [Some (Ok
    (predicate, args))] on success. *)
let parse_fact line : (string * Value.t list, string) result option =
  let fact = String.trim line in
  if fact = "" || String.starts_with ~prefix:"%" fact || String.starts_with ~prefix:"#" fact then
    None
  else
    let fact =
      if String.ends_with ~suffix:"." fact then String.sub fact 0 (String.length fact - 1)
      else fact
    in
    match String.index_opt fact '(' with
    | None -> None
    | Some _ -> (
        match Lexer.tokenize fact with
        | Error e -> Some (Error e)
        | Ok tokens -> (
            match tokens with
            | Lexer.Ident predicate :: Lexer.LParen :: rest -> (
                match List.rev rest with
                | Lexer.RParen :: rev_inner -> (
                    let inner = List.rev rev_inner in
                    let rec split_commas acc current = function
                      | [] ->
                          let current = List.rev current in
                          List.rev (if current = [] then acc else current :: acc)
                      | Lexer.Comma :: rest -> split_commas (List.rev current :: acc) [] rest
                      | tok :: rest -> split_commas acc (tok :: current) rest
                    in
                    let groups = if inner = [] then [] else split_commas [] [] inner in
                    let rec parse_args = function
                      | [] -> Ok []
                      | [ tok ] :: rest -> (
                          match Lexer.value_of_token tok with
                          | Error e -> Error e
                          | Ok v -> ( match parse_args rest with
                                      | Ok vs -> Ok (v :: vs)
                                      | Error _ as e -> e ))
                      | _ :: _ ->
                          Error (Printf.sprintf "Invalid argument in fact: %s" line)
                    in
                    match parse_args groups with
                    | Error e -> Some (Error e)
                    | Ok args -> Some (Ok (predicate, args)))
                | _ -> Some (Error (Printf.sprintf "Malformed fact (missing closing parenthesis): %s" line)))
            | _ -> None))
