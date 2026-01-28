(** Parse_predicate: Parsing logic for predicate facts
    
    This module handles parsing of predicate facts from various sources.
    It's used by both the sync pipeline and the query engine.
*)

(** Parse a quoted string, returning (content, end_position) *)
let parse_quoted_string s start_pos =
  let len = String.length s in
  if start_pos >= len || s.[start_pos] <> '"' then
    None
  else
    let rec find_close i acc =
      if i >= len then
        None  (* unclosed string *)
      else if s.[i] = '\\' && i + 1 < len then
        (* escaped character *)
        let escaped = match s.[i + 1] with
          | 'n' -> '\n'
          | 't' -> '\t'
          | 'r' -> '\r'
          | '\\' -> '\\'
          | '"' -> '"'
          | c -> c
        in
        find_close (i + 2) (acc ^ String.make 1 escaped)
      else if s.[i] = '"' then
        (* found closing quote *)
        Some (acc, i + 1)
      else
        find_close (i + 1) (acc ^ String.make 1 s.[i])
    in
    find_close (start_pos + 1) ""

(** Parse a single fact into predicate name and arguments
    
    Examples:
    - "created(tina_keane, she)." -> Some ("created", ["tina_keane"; "she"])
    - "keyword(doc_123, \"machine learning\")." -> Some ("keyword", ["doc_123"; "machine learning"])
    - "shown_in(she, exhibition)" -> Some ("shown_in", ["she"; "exhibition"])
    - "created( tina_keane , she )." -> Some ("created", ["tina_keane"; "she"])
    - "not_a_fact" -> None
    
    Handles:
    - Quoted strings with spaces and escapes
    - Optional trailing period
    - Whitespace around arguments
    - Comments (returns None)
*)
let parse_fact fact =
  let fact = String.trim fact in
  
  (* Skip empty lines and comments *)
  if fact = "" || 
     String.starts_with ~prefix:"%" fact ||
     String.starts_with ~prefix:"#" fact then
    None
  else
    (* Remove optional trailing period *)
    let fact = 
      if String.ends_with ~suffix:"." fact then
        String.sub fact 0 (String.length fact - 1)
      else fact
    in
    
    (* Find opening parenthesis *)
    match String.index_opt fact '(' with
    | None -> None
    | Some idx ->
        let predicate = String.sub fact 0 idx in
        let rest = String.sub fact (idx + 1) (String.length fact - idx - 1) in
        
        (* Remove closing parenthesis *)
        let rest = 
          if String.ends_with ~suffix:")" rest then
            String.sub rest 0 (String.length rest - 1)
          else rest
        in
        
        (* Parse arguments, respecting quoted strings *)
        let rec split_args acc current in_string escaped i =
          if i >= String.length rest then
            let final = String.trim current in
            if final = "" then List.rev acc else List.rev (final :: acc)
          else
            let c = rest.[i] in
            if escaped then
              split_args acc (current ^ String.make 1 c) in_string false (i + 1)
            else if c = '\\' && in_string then
              split_args acc (current ^ String.make 1 c) in_string true (i + 1)
            else if c = '"' then
              split_args acc (current ^ String.make 1 c) (not in_string) false (i + 1)
            else if c = ',' && not in_string then
              let trimmed = String.trim current in
              split_args (trimmed :: acc) "" false false (i + 1)
            else
              split_args acc (current ^ String.make 1 c) in_string false (i + 1)
        in
        
        let arg_strings = split_args [] "" false false 0 in
        
        (* Parse arguments preserving type information *)
        let args = List.map (fun arg ->
          let arg = String.trim arg in
          if String.length arg >= 2 && arg.[0] = '"' then
            match parse_quoted_string arg 0 with
            | Some (content, _) -> Types.String content  (* Quoted string *)
            | None -> Types.Atom arg  (* malformed quote, treat as atom *)
          else
            Types.Atom arg  (* Unquoted atom *)
        ) arg_strings in
        
        Some (predicate, args)
