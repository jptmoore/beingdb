(** Query_parser: Parse BeingDB query language
    
    Query syntax:
    - Variables start with uppercase: Work, Artist, Venue
    - Atoms start with lowercase: tina_keane, she, video
    - Wildcard: _
    - Multiple predicates separated by comma
    
    Example: "created(tina_keane, Work), shown_in(Work, Exhibition)"
*)

(** Term in a query predicate *)
type term =
  | Atom of string      (* lowercase atom: she, video *)
  | Var of string       (* Uppercase variable: Work, Artist *)
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

(** Parse a single term *)
let parse_term s =
  let s = String.trim s in
  if s = "_" then
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
      
      (* Parse arguments *)
      let args = 
        String.split_on_char ',' rest
        |> List.map parse_term
      in
      
      Some { name; args }

(** Extract all variables from a query *)
let extract_variables patterns =
  let extract_from_term = function
    | Var v -> [v]
    | Atom _ | Wildcard -> []
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
  | Wildcard -> "_"

(** Convert pattern to string for debugging *)
let pattern_to_string pattern =
  let args_str = String.concat ", " (List.map term_to_string pattern.args) in
  Printf.sprintf "%s(%s)" pattern.name args_str

(** Convert query to string for debugging *)
let query_to_string query =
  String.concat ", " (List.map pattern_to_string query.patterns)
