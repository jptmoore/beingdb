(** Parse_declaration: optional predicate declarations in source files.

    A declaration is a PlDoc-style structured comment: a [%!] line naming
    the predicate, optionally with its argument roles, followed by
    optional [%] comment lines forming the description. It ends at the
    first line that does not start with [%] (a blank line or a fact) or
    at the next [%!] line. Ordinary [%] comments are never declarations.

    {[
      %! created_by
      %  Relates a work to the artist or creator who made it.

      %! created_by(Work, Artist)

      %! created_by(Work:work, Artist:person)
      %  Relates a work to the artist or creator who made it.
    ]}

    Each argument is a role ([[A-Z][A-Za-z0-9_]*]), optionally followed
    by [:semantic_type] ([[a-z][a-z0-9_]*]). A bare [%! name] declares
    only a description and needs at least one description line. An empty
    [%] line separates description paragraphs; other lines in a
    paragraph are joined with a single space. Because declarations are
    comments, sources containing them still compile with BeingDB
    versions that predate them. *)

type item = { name : string; declaration : Predicate_declaration.t; line : int (** 1-based *) }

let check_name name =
  if Result.is_error (Query_validation.validate_predicate_name name) then
    Error (Printf.sprintf "invalid predicate name '%s'" name)
  else Ok name

(** Parse the text after [%!]: a predicate name, optionally followed by
    an argument list, e.g. ["created_by"] or ["created_by(Work, Artist:person)"].
    Returns the name and the declared arguments ([None] for a bare name). *)
let parse_signature text =
  let text = String.trim text in
  let text =
    if String.ends_with ~suffix:"." text then String.trim (String.sub text 0 (String.length text - 1)) else text
  in
  match String.index_opt text '(' with
  | None -> Result.map (fun name -> (name, None)) (check_name text)
  | Some lp ->
      let name = String.trim (String.sub text 0 lp) in
      let rest = String.sub text (lp + 1) (String.length text - lp - 1) in
      if not (String.ends_with ~suffix:")" rest) then Error "expected name(Role, ...) with nothing after ')'"
      else
        match check_name name with
        | Error msg -> Error msg
        | Ok name ->
        let inner = String.trim (String.sub rest 0 (String.length rest - 1)) in
        let parts = if inner = "" then [] else List.map String.trim (String.split_on_char ',' inner) in
        let arguments =
          List.map
            (fun part ->
              match String.index_opt part ':' with
              | None -> { Predicate_declaration.role = part; semantic_type = None }
              | Some i ->
                  {
                    Predicate_declaration.role = String.trim (String.sub part 0 i);
                    semantic_type = Some (String.trim (String.sub part (i + 1) (String.length part - i - 1)));
                  })
            parts
        in
        Ok (name, Some arguments)

let is_comment line = String.starts_with ~prefix:"%" line
let is_signature line = String.starts_with ~prefix:"%!" line

let description_of lines =
  let paragraphs, current =
    List.fold_left
      (fun (paragraphs, current) line ->
        if line = "" then if current = [] then (paragraphs, []) else (List.rev current :: paragraphs, [])
        else (paragraphs, line :: current))
      ([], []) lines
  in
  let paragraphs = List.rev (if current = [] then paragraphs else List.rev current :: paragraphs) in
  match paragraphs with [] -> None | ps -> Some (String.concat "\n\n" (List.map (String.concat " ") ps))

(** Every declaration in a source file's lines, in source order, plus a
    warning (prefixed with its line number) for each [%!] line that could
    not be parsed. *)
let extract lines =
  let lines = Array.of_list (List.map String.trim lines) in
  let n = Array.length lines in
  let rec scan i items warnings =
    if i >= n then (List.rev items, List.rev warnings)
    else if not (is_signature lines.(i)) then scan (i + 1) items warnings
    else
      let rec body j acc =
        if j < n && is_comment lines.(j) && not (is_signature lines.(j)) then
          body (j + 1) (String.trim (String.sub lines.(j) 1 (String.length lines.(j) - 1)) :: acc)
        else (j, List.rev acc)
      in
      let next, desc_lines = body (i + 1) [] in
      let sig_text = String.sub lines.(i) 2 (String.length lines.(i) - 2) in
      match parse_signature sig_text with
      | Error e -> scan next items (Printf.sprintf "line %d: ignoring declaration: %s" (i + 1) e :: warnings)
      | Ok (name, arguments) -> (
          match Predicate_declaration.make ~arguments ~description:(description_of desc_lines) with
          | Ok declaration -> scan next ({ name; declaration; line = i + 1 } :: items) warnings
          | Error e -> scan next items (Printf.sprintf "line %d: ignoring declaration: %s" (i + 1) e :: warnings))
  in
  scan 0 [] []

(** The declaration to compile for [predicate] given its facts' [arity]:
    the first declaration naming it, if any declared arguments match the
    arity (a description-only declaration always applies). Declarations
    for other predicates, repeated declarations and arity mismatches are
    reported as warnings and ignored, so declarations can never make an
    otherwise valid source fail to compile. *)
let select ~predicate ~arity items =
  let mine, others = List.partition (fun it -> it.name = predicate) items in
  let other_warnings =
    List.map
      (fun it -> Printf.sprintf "line %d: ignoring declaration for '%s' (this source defines '%s')" it.line it.name predicate)
      others
  in
  match mine with
  | [] -> (None, other_warnings)
  | first :: repeats ->
      let repeat_warnings =
        List.map (fun it -> Printf.sprintf "line %d: ignoring repeated declaration for '%s'" it.line predicate) repeats
      in
      match Predicate_declaration.arity first.declaration with
      | Some declared when declared <> arity ->
        ( None,
          (Printf.sprintf "line %d: ignoring declaration %s: it has %d argument(s) but the facts have %d" first.line
             (Predicate_declaration.signature predicate first.declaration)
             declared arity
          :: repeat_warnings)
          @ other_warnings )
      | _ -> (Some first.declaration, repeat_warnings @ other_warnings)
