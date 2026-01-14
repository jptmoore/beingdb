(** Parse_predicate: Parsing logic for predicate facts
    
    This module handles parsing of predicate facts from various sources.
    It's used by both the sync pipeline and the query engine.
*)

(** Parse a single fact into predicate name and arguments
    
    Examples:
    - "created(tina_keane, she)." -> Some ("created", ["tina_keane"; "she"])
    - "shown_in(she, exhibition)" -> Some ("shown_in", ["she"; "exhibition"])
    - "created( tina_keane , she )." -> Some ("created", ["tina_keane"; "she"])
    - "not_a_fact" -> None
    
    Handles:
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
        
        (* Parse arguments *)
        let args = 
          String.split_on_char ',' rest
          |> List.map String.trim
        in
        
        Some (predicate, args)
