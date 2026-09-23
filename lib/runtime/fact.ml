(** See {!Fact} (mli) for documentation. *)

type t = { predicate : string; arguments : Value.t list }

let make predicate arguments = { predicate; arguments }

let write_chunk buf s =
  Buffer.add_string buf (string_of_int (String.length s));
  Buffer.add_char buf ':';
  Buffer.add_string buf s

let read_chunk s pos =
  match String.index_from_opt s pos ':' with
  | None -> None
  | Some colon -> (
      match int_of_string_opt (String.sub s pos (colon - pos)) with
      | None -> None
      | Some len when len < 0 || colon + 1 + len > String.length s -> None
      | Some len ->
          let value = String.sub s (colon + 1) len in
          Some (value, colon + 1 + len))

let canonical_proposition t =
  let buf = Buffer.create 128 in
  Buffer.add_string buf t.predicate;
  Buffer.add_char buf '/';
  Buffer.add_string buf (string_of_int (List.length t.arguments));
  List.iter
    (fun v ->
      Buffer.add_char buf '|';
      Buffer.add_string buf (Value.type_name v);
      Buffer.add_char buf ':';
      Buffer.add_string buf (Value.canonical_string v))
    t.arguments;
  Buffer.contents buf

let fact_id t = Digestif.SHA256.to_hex (Digestif.SHA256.digest_string (canonical_proposition t))

let encode t =
  let buf = Buffer.create 128 in
  write_chunk buf t.predicate;
  write_chunk buf (string_of_int (List.length t.arguments));
  List.iter
    (fun v ->
      write_chunk buf (Value.type_name v);
      write_chunk buf (Value.canonical_string v))
    t.arguments;
  Buffer.contents buf

let decode s =
  match read_chunk s 0 with
  | None -> Error "Malformed fact encoding: missing predicate"
  | Some (predicate, pos) -> (
      match read_chunk s pos with
      | None -> Error "Malformed fact encoding: missing arity"
      | Some (arity_str, pos) -> (
          match int_of_string_opt arity_str with
          | None -> Error "Malformed fact encoding: invalid arity"
          | Some arity ->
              let rec read_args pos n acc =
                if n = 0 then Ok (List.rev acc, pos)
                else
                  match read_chunk s pos with
                  | None -> Error "Malformed fact encoding: missing argument type"
                  | Some (type_name, pos) -> (
                      match read_chunk s pos with
                      | None -> Error "Malformed fact encoding: missing argument value"
                      | Some (value_str, pos) -> (
                          match Value.of_canonical ~type_name value_str with
                          | Error e -> Error e
                          | Ok v -> read_args pos (n - 1) (v :: acc)))
              in
              (match read_args pos arity [] with
               | Error _ as e -> e
               | Ok (arguments, _) -> Ok { predicate; arguments })))
