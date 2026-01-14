(** Query_parser: Parse BeingDB query language
    
    Query syntax:
    - Variables start with uppercase: Work, Artist, Venue
    - Atoms start with lowercase: tina_keane, she, video
    - Strings in quotes: "machine learning", "text with spaces"
    - Wildcard: _
    - Multiple predicates separated by comma
    
    Example: "created(tina_keane, Work), keyword(Work, \"machine learning\")"
*)

(** Term in a query predicate *)
type term =
  | Atom of string      (* lowercase atom: she, video *)
  | Var of string       (* Uppercase variable: Work, Artist *)
  | String of string    (* quoted string: "machine learning" *)
  | Wildcard            (* underscore: _ *)

(** Single predicate pattern in a query *)
type predicate_pattern = {
  name: string;         (* predicate name *)
  args: term list;      (* argument terms *)
}

(** Complete query with multiple predicates *)
type query = {
  patterns: predicate_pattern list;
  variables: string list;  (* unique variables in query *)
}

(** Parse a quoted string with escape sequences *)
let parse_quoted_string s =
  let len = String.length s in
  if len < 2 || s.[0] <> '"' then
    None
  else
    (* Find closing quote, handling escapes *)
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
    match find_close 1 "" with
    | Some (content, end_pos) -> Some (content, end_pos)
    | None -> None

(** Parse a single term *)
let parse_term s =
  let s = String.trim s in
  (* Check for quoted string first *)
  if s <> "" && s.[0] = '"' then
    match parse_quoted_string s with
    | Some (content, _) -> String content
    | None -> Atom s  (* malformed string, treat as atom *)
  else if s = "_" then
    Wildcard
  else if s <> "" && Char.uppercase_ascii s.[0] = s.[0] then
    Var s
  else
    Atom s

(** Parse a single predicate pattern like "created(tina_keane, Work)" *)
let parse_predicate_pattern s =
  let s = String.trim s in
  
  match String.index_opt s '(' with
  | None -> None
  | Some idx ->
      let name = String.sub s 0 idx |> String.trim in
      let rest = String.sub s (idx + 1) (String.length s - idx - 1) in
      
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
      let args = List.map parse_term arg_strings in
      
      Some { name; args }

(** Extract all variables from a query *)
let extract_variables patterns =
  let extract_from_term = function
    | Var v -> [v]
    | Atom _ | String _ | Wildcard -> []
  in
  
  let extract_from_pattern pattern =
    List.concat_map extract_from_term pattern.args
  in
  
  patterns
  |> List.concat_map extract_from_pattern
  |> List.sort_uniq String.compare

(** Split query string by commas at top level (outside parentheses) *)
let split_predicates s =
  let rec split_at_commas acc current depth i =
    if i >= String.length s then
      if current = "" then List.rev acc else List.rev (current :: acc)
    else
      let c = s.[i] in
      match c with
      | '(' -> split_at_commas acc (current ^ String.make 1 c) (depth + 1) (i + 1)
      | ')' -> split_at_commas acc (current ^ String.make 1 c) (depth - 1) (i + 1)
      | ',' when depth = 0 ->
          let trimmed = String.trim current in
          if trimmed = "" then
            split_at_commas acc "" 0 (i + 1)
          else
            split_at_commas (trimmed :: acc) "" 0 (i + 1)
      | _ -> split_at_commas acc (current ^ String.make 1 c) depth (i + 1)
  in
  split_at_commas [] "" 0 0

(** Parse a complete query string
    Example: "created(Artist, Work), shown_in(Work, Exhibition)"
*)
let parse_query s =
  let s = String.trim s in
  
  (* Handle optional trailing period *)
  let s = 
    if String.ends_with ~suffix:"." s then
      String.sub s 0 (String.length s - 1)
    else s
  in
  
  (* Split by comma respecting parentheses *)
  let predicate_strings = split_predicates s in
  
  (* Parse each predicate *)
  let patterns = 
    List.filter_map parse_predicate_pattern predicate_strings
  in
  
  if List.length patterns = 0 then
    None
  else
    let variables = extract_variables patterns in
    Some { patterns; variables }

(** Convert term to string for debugging *)
let term_to_string = function
  | Atom s -> s
  | Var v -> v
  | String s -> "\"" ^ s ^ "\""
  | Wildcard -> "_"

(** Convert pattern to string for debugging *)
let pattern_to_string pattern =
  let args_str = String.concat ", " (List.map term_to_string pattern.args) in
  Printf.sprintf "%s(%s)" pattern.name args_str

(** Convert query to string for debugging *)
let query_to_string query =
  String.concat ", " (List.map pattern_to_string query.patterns)
