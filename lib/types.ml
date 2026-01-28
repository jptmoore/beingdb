(** Core types for BeingDB *)

(** Argument values with explicit types *)
type arg_value = 
  | Atom of string      (** Unquoted identifier/constant *)
  | String of string    (** Quoted text/string literal *)

(** Convert arg_value to string (losing type info) *)
let arg_to_string = function
  | Atom s -> s
  | String s -> s

(** Get the string content regardless of type *)
let content_of_arg = arg_to_string

(** Check if two arg_values match (for pattern matching) *)
let args_match pattern value =
  match pattern, value with
  | Atom "_", _ -> true  (* Wildcard matches anything *)
  | Atom p, Atom v -> p = v
  | Atom p, String v -> p = v
  | String p, String v -> p = v
  | String p, Atom v -> p = v

(** Pretty print arg_value *)
let pp_arg_value fmt = function
  | Atom s -> Format.fprintf fmt "%s" s
  | String s -> Format.fprintf fmt "\"%s\"" s
