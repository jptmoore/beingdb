(** See {!Lexer} (mli) for documentation. *)

type token =
  | Ident of string
  | Str of string * string option
  | Num of string
  | At of string
  | Uri of string
  | LParen
  | RParen
  | Comma
  | Op of string
  | Underscore

let is_ident_start c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
let is_ident_char c = is_ident_start c || (c >= '0' && c <= '9')
let is_digit c = c >= '0' && c <= '9'

(** Parse a double-quoted string starting at [start_pos] (the position of
    the opening quote). Returns [(content, end_pos)] where [end_pos] is
    the index just past the closing quote. *)
let parse_quoted s start_pos =
  let len = String.length s in
  if start_pos >= len || s.[start_pos] <> '"' then None
  else
    let rec find_close i acc =
      if i >= len then None
      else if s.[i] = '\\' && i + 1 < len then
        let escaped =
          match s.[i + 1] with
          | 'n' -> '\n'
          | 't' -> '\t'
          | 'r' -> '\r'
          | '\\' -> '\\'
          | '"' -> '"'
          | c -> c
        in
        find_close (i + 2) (acc ^ String.make 1 escaped)
      else if s.[i] = '"' then Some (acc, i + 1)
      else find_close (i + 1) (acc ^ String.make 1 s.[i])
    in
    find_close (start_pos + 1) ""

let tokenize s =
  let len = String.length s in
  let tokens = ref [] in
  let error = ref None in
  let i = ref 0 in
  let add t = tokens := t :: !tokens in
  while !i < len && !error = None do
    let c = s.[!i] in
    if c = ' ' || c = '\t' || c = '\n' || c = '\r' then incr i
    else if c = '(' then ( add LParen; incr i )
    else if c = ')' then ( add RParen; incr i )
    else if c = ',' then ( add Comma; incr i )
    else if c = '!' && !i + 1 < len && s.[!i + 1] = '=' then ( add (Op "!="); i := !i + 2 )
    else if c = '<' && !i + 1 < len && s.[!i + 1] = '=' then ( add (Op "<="); i := !i + 2 )
    else if c = '>' && !i + 1 < len && s.[!i + 1] = '=' then ( add (Op ">="); i := !i + 2 )
    else if c = '=' then ( add (Op "="); incr i )
    else if c = '<' && !i + 1 < len && s.[!i + 1] <> ' ' && String.index_from_opt s (!i + 1) '>' <> None
            && (match String.index_from_opt s (!i + 1) '<' with
                | Some next_lt -> ( match String.index_from_opt s (!i + 1) '>' with Some gt -> gt < next_lt | None -> false)
                | None -> true) then (
      match String.index_from_opt s (!i + 1) '>' with
      | None -> error := Some "Unclosed URI literal (missing '>')"
      | Some close_pos ->
          add (Uri (String.sub s (!i + 1) (close_pos - !i - 1)));
          i := close_pos + 1)
    else if c = '<' then ( add (Op "<"); incr i )
    else if c = '>' then ( add (Op ">"); incr i )
    else if c = '"' then (
      match parse_quoted s !i with
      | None -> error := Some "Unclosed string literal"
      | Some (content, end_pos) ->
          if end_pos < len && s.[end_pos] = '@' then (
            let lang_start = end_pos + 1 in
            let j = ref lang_start in
            while !j < len && (is_ident_char s.[!j] || s.[!j] = '-') do
              incr j
            done;
            if !j = lang_start then (
              add (Str (content, None));
              i := end_pos)
            else (
              add (Str (content, Some (String.sub s lang_start (!j - lang_start))));
              i := !j))
          else (
            add (Str (content, None));
            i := end_pos))
    else if c = '@' then (
      let start = !i + 1 in
      let j = ref start in
      while
        !j < len
        && (match s.[!j] with ' ' | '\t' | '\n' | '\r' | ',' | ')' | '(' -> false | _ -> true)
      do
        incr j
      done;
      if !j = start then error := Some "Empty '@' literal"
      else (
        add (At (String.sub s start (!j - start)));
        i := !j))
    else if is_digit c || (c = '-' && !i + 1 < len && is_digit s.[!i + 1]) then (
      let start = !i in
      let j = ref (!i + 1) in
      while !j < len && is_digit s.[!j] do
        incr j
      done;
      if !j < len && s.[!j] = '.' && !j + 1 < len && is_digit s.[!j + 1] then (
        incr j;
        while !j < len && is_digit s.[!j] do
          incr j
        done);
      add (Num (String.sub s start (!j - start)));
      i := !j)
    else if is_ident_start c then (
      let start = !i in
      let j = ref !i in
      while !j < len && is_ident_char s.[!j] do
        incr j
      done;
      let text = String.sub s start (!j - start) in
      add (if text = "_" then Underscore else Ident text);
      i := !j)
    else error := Some (Printf.sprintf "Unexpected character '%c' at position %d" c !i)
  done;
  match !error with Some e -> Error e | None -> Ok (List.rev !tokens)

let parse_at_value raw =
  if String.contains raw 'T' then
    match Calendar.parse_instant raw with
    | Ok t -> Ok (Value.Instant t)
    | Error e -> Error e
  else
    let stripped =
      if String.length raw > 0 && raw.[0] = '-' then String.sub raw 1 (String.length raw - 1)
      else raw
    in
    let dash_count = String.fold_left (fun acc c -> if c = '-' then acc + 1 else acc) 0 stripped in
    match dash_count with
    | 0 -> ( match Calendar.parse_year raw with Ok y -> Ok (Value.Year y) | Error e -> Error e )
    | 1 -> (
        match Calendar.parse_year_month raw with
        | Ok (y, m) -> Value.make_year_month ~year:y ~month:m
        | Error e -> Error e)
    | 2 -> (
        match Calendar.parse_date raw with
        | Ok (y, m, d) -> Value.make_date ~year:y ~month:m ~day:d
        | Error e -> Error e)
    | _ -> Error (Printf.sprintf "Invalid temporal literal: @%s" raw)

let value_of_token = function
  | Ident "true" -> Ok (Value.Boolean true)
  | Ident "false" -> Ok (Value.Boolean false)
  | Ident s -> Ok (Value.Atom s)
  | Num raw ->
      if String.contains raw '.' then
        match Decimal.of_string raw with
        | Ok d -> Ok (Value.Decimal d)
        | Error e -> Error e
      else (
        match Int64.of_string_opt raw with
        | Some n -> Ok (Value.Integer n)
        | None -> Error (Printf.sprintf "Integer literal out of range: %s" raw))
  | Str (content, None) -> Ok (Value.String content)
  | Str (content, Some lang) -> Value.make_lang_string ~value:content ~language:lang
  | Uri content -> Value.make_uri content
  | At raw -> parse_at_value raw
  | LParen | RParen | Comma | Op _ | Underscore -> Error "Expected a literal value"
