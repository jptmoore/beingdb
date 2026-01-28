(** Pack Backend: High-performance runtime snapshot
    
    Storage format: Type-aware hybrid encoding
    - Atoms (identifiers): stored in path - "5:alice:7:project"
    - Strings (text): stored in value - "$:0:$:1" in path, "5:text112:longer text2" in value
    - Type information from parser determines storage strategy
    
    Examples:
    - person(alice, bob) → Path: ["person"; "5:alice:3:bob"], Value: ""
    - doc(id, "Large text") → Path: ["person"; "2:id:$:0"], Value: "10:Large text"
*)

open Lwt.Syntax

(** Encode args with explicit type information:
    Atoms go inline as "5:alice", Strings get placeholders "$:0", "$:1", ... 
    Returns (encoded_path, string_values_list) *)
let encode_args_typed args =
  let string_values = ref [] in
  let string_count = ref 0 in
  
  let encoded_parts = List.map (fun arg ->
    match arg with
    | Types.String text ->
        (* Store string in value field, use $:N as placeholder *)
        string_values := text :: !string_values;
        let placeholder = Printf.sprintf "$:%d" !string_count in
        incr string_count;
        placeholder  (* No length prefix for placeholders *)
    | Types.Atom atom ->
        (* Store atom inline in path with length prefix *)
        Printf.sprintf "%d:%s" (String.length atom) atom
  ) args in
  
  let path_encoded = String.concat ":" encoded_parts in
  let value_encoded = 
    if !string_values = [] then None
    else 
      (* Length-prefixed format: "<len>:<string><len>:<string>..." *)
      let encoded_strings = List.rev !string_values |> List.map (fun s ->
        Printf.sprintf "%d:%s" (String.length s) s
      ) in
      Some (String.concat "" encoded_strings)
  in
  (path_encoded, value_encoded)

(** Decode args from path and optional value field *)
let decode_args_typed path_encoded value_opt =
  (* Parse path_encoded handling both "N:value" (atoms) and "$:N" (string refs) *)
  let rec parse pos acc =
    if pos >= String.length path_encoded then
      List.rev acc
    else if pos + 2 <= String.length path_encoded && 
            String.sub path_encoded pos 2 = "$:" then
      (* String placeholder: $:N *)
      let rest = String.sub path_encoded (pos + 2) (String.length path_encoded - pos - 2) in
      (match String.index_opt rest ':' with
       | Some next_colon ->
           let idx_str = String.sub rest 0 next_colon in
           let placeholder = "$:" ^ idx_str in
           parse (pos + 2 + next_colon + 1) (placeholder :: acc)
       | None ->
           (* Last element - must preserve $: prefix *)
           let placeholder = "$:" ^ rest in
           List.rev (placeholder :: acc))
    else
      (* Regular atom: N:value format *)
      (match String.index_from_opt path_encoded pos ':' with
       | None -> List.rev acc
       | Some colon_pos ->
           let len_str = String.sub path_encoded pos (colon_pos - pos) in
           (match int_of_string_opt len_str with
           | None -> 
               (* Not a number, malformed *)
               List.rev acc
           | Some len when len < 0 || len > 1_000_000 ->
               (* Reject negative or unreasonably large lengths *)
               List.rev acc
           | Some len ->
               let value_start = colon_pos + 1 in
               if value_start + len > String.length path_encoded || value_start + len < value_start then
                 (* Out of bounds or integer overflow *)
                 List.rev acc
               else
                 let value = String.sub path_encoded value_start len in
                 parse (value_start + len + 1) (value :: acc)))
  in
  let path_parts = parse 0 [] in
  
  (* Now replace $:N placeholders with actual strings from value *)
  match value_opt with
  | None -> 
      (* No strings, all atoms *)
      List.map (fun part -> Types.Atom part) path_parts
  | Some value_data ->
      (* Parse length-prefixed strings: "<len>:<string><len>:<string>..." *)
      let rec parse_strings pos acc =
        if pos >= String.length value_data then
          List.rev acc
        else
          match String.index_from_opt value_data pos ':' with
          | None -> List.rev acc
          | Some colon_pos ->
              let len_str = String.sub value_data pos (colon_pos - pos) in
              match int_of_string_opt len_str with
              | None -> List.rev acc
              | Some len when len < 0 || len > 1_000_000 -> List.rev acc
              | Some len ->
                  let value_start = colon_pos + 1 in
                  if value_start + len > String.length value_data then
                    List.rev acc
                  else
                    let value = String.sub value_data value_start len in
                    parse_strings (value_start + len) (value :: acc)
      in
      let string_values = parse_strings 0 [] in
      List.map (fun part ->
        if String.length part >= 3 && String.sub part 0 2 = "$:" then
          (* Placeholder: extract index and replace with String type *)
          (match int_of_string_opt (String.sub part 2 (String.length part - 2)) with
          | Some idx when idx >= 0 && idx < List.length string_values ->
              Types.String (List.nth string_values idx)
          | _ -> Types.Atom part)  (* Invalid placeholder, treat as atom *)
        else
          Types.Atom part  (* Regular atom *)
      ) path_parts

(** Size threshold for switching to value-based storage (1KB) *)
let storage_threshold = 1024

module Conf = struct
  let entries = 32
  let stable_hash = 256
  let contents_length_header = Some `Varint
  let inode_child_order = `Seeded_hash
  let forbid_empty_dir_persistence = false
end

module StoreMaker = Irmin_pack_unix.KV(Conf)
module Store = StoreMaker.Make(Irmin.Contents.String)
module Store_info = Irmin_unix.Info(Store.Info)

let info message = Store_info.v ~author:"beingdb" "%s" message

type t = Store.t
type repo = Store.Repo.t

(** Pack configuration with minimal indexing strategy for GC support *)
let pack_config ?(fresh=false) path =
  Irmin_pack.config path
    ~fresh
    ~indexing_strategy:Irmin_pack.Indexing_strategy.minimal

let create ~fname = 
  Lwt_main.run (
    let config = pack_config fname in
    let* repo = Store.Repo.v config in
    Store.main repo
  )

let init ?(fresh=false) path =
  let config = pack_config ~fresh path in
  let* repo = Store.Repo.v config in
  Store.main repo

(** Close repository to free file descriptors *)
let close_repo repo =
  Store.Repo.close repo

(** Encode fact as 2-level path with type-aware storage *)
let fact_to_path predicate_name args =
  let (path_encoded, value_opt) = encode_args_typed args in
  ([predicate_name; path_encoded], value_opt)

(** Decode 2-level path back to (predicate, args) with value field *)
let path_to_fact path value_opt =
  match path with
  | [predicate; path_encoded] ->
      Some (predicate, decode_args_typed path_encoded value_opt)
  | _ -> None

(** Query predicate with pattern matching and pagination. 
    Handles type-aware storage. *)
let query_predicate ?offset ?limit store predicate_name pattern =
  let* entries = Store.list store [predicate_name] in
  
  let offset_val = Option.value offset ~default:0 in
  let limit_val = Option.value limit ~default:max_int in
  
  let matches_pattern args =
    List.length args = List.length pattern &&
    List.for_all2 Types.args_match pattern args
  in
  
  let count = ref 0 in
  let results = ref [] in
  
  (* Parse each immediate child *)
  let* () = Lwt_list.iter_s (fun (step, tree) ->
    let path_encoded = Irmin.Type.to_string Store.Path.step_t step in
    
    (* Read value field (may be empty) *)
    let* value_opt = Store.Tree.find tree [] in
    let args = decode_args_typed path_encoded value_opt in
    
    if matches_pattern args then begin
      if !count >= offset_val && !count - offset_val < limit_val then
        results := args :: !results;
      incr count
    end;
    Lwt.return ()
  ) entries in
  
  Lwt.return (List.rev !results)

(** Query all facts for a predicate. Handles type-aware storage. *)
let query_all store predicate_name =
  let* entries = Store.list store [predicate_name] in
  
  Lwt_list.map_s (fun (step, tree) ->
    let path_encoded = Irmin.Type.to_string Store.Path.step_t step in
    let* value_opt = Store.Tree.find tree [] in
    Lwt.return (decode_args_typed path_encoded value_opt)
  ) entries

(** List all predicates *)
let list_predicates store =
  let* entries = Store.list store [] in
  entries
  |> List.map (fun (step, _tree) -> 
      Irmin.Type.to_string Store.Path.step_t step)
  |> Lwt.return

(** Get arity by sampling first fact *)
let get_predicate_arity store predicate_name =
  let* all = query_all store predicate_name in
  match all with
  | first :: _ -> Lwt.return (Some (List.length first))
  | [] -> Lwt.return None

(** List all predicates with their arities *)
let list_predicates_with_arity store =
  let* predicates = list_predicates store in
  Lwt_list.map_s (fun pred ->
    let* arity = get_predicate_arity store pred in
    match arity with
    | Some a -> Lwt.return (pred, a)
    | None -> Lwt.return (pred, 0)
  ) predicates

(** Write fact to store with hybrid storage *)
let write_fact store predicate_name args =
  let (path, value_opt) = fact_to_path predicate_name args in
  let value = Option.value value_opt ~default:"" in
  Store.set_exn store path value ~info:(info "Materialize fact")

let clear store =
  Store.remove_exn store [] ~info:(info "Clear all facts")
