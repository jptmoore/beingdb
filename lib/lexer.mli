(** Lexer: shared tokenizer for BeingDB's literal syntax, used both when
    parsing facts (source predicates) and when parsing queries. *)

type token =
  | Ident of string
  | Str of string * string option  (** content, optional BCP-47 language tag *)
  | Num of string  (** raw numeral text, e.g. ["1979"], ["-0.92"] *)
  | At of string  (** raw text following ['@'], e.g. ["1972"], ["1972-05-14"] *)
  | Uri of string  (** content between ['<'] and ['>'] *)
  | LParen
  | RParen
  | Comma
  | Op of string  (** one of "=", "!=", "<", "<=", ">", ">=" *)
  | Underscore

val tokenize : string -> (token list, string) result

(** Interpret a single literal token (everything except [LParen], [RParen],
    [Comma], [Op] and structural [Underscore]) as a typed {!Value.t}. *)
val value_of_token : token -> (Value.t, string) result
