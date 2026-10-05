(** See {!Predicate_declaration} (mli) for documentation. *)

type argument = { role : string; semantic_type : string option }
type t = { arguments : argument list; description : string option }

let is_lower = function 'a' .. 'z' -> true | _ -> false
let is_upper = function 'A' .. 'Z' -> true | _ -> false
let is_digit = function '0' .. '9' -> true | _ -> false

let valid_role s =
  String.length s > 0
  && is_upper s.[0]
  && String.for_all (fun c -> is_lower c || is_upper c || is_digit c || c = '_') s

let valid_semantic_type s =
  String.length s > 0 && is_lower s.[0] && String.for_all (fun c -> is_lower c || is_digit c || c = '_') s

let make ~arguments ~description =
  let rec check seen = function
    | [] -> Ok ()
    | { role; semantic_type } :: rest ->
        if not (valid_role role) then
          Error (Printf.sprintf "invalid role '%s' (expected an uppercase-initial name such as Work)" role)
        else if List.mem role seen then Error (Printf.sprintf "duplicate role '%s'" role)
        else (
          match semantic_type with
          | Some ty when not (valid_semantic_type ty) ->
              Error (Printf.sprintf "invalid semantic type '%s' for %s (expected a lowercase name such as person)" ty role)
          | _ -> check (role :: seen) rest)
  in
  match check [] arguments with
  | Error _ as e -> e
  | Ok () ->
      let description = match Option.map String.trim description with Some "" | None -> None | Some d -> Some d in
      Ok { arguments; description }

let arity t = List.length t.arguments

let signature name t =
  let arg a = match a.semantic_type with Some ty -> a.role ^ ":" ^ ty | None -> a.role in
  Printf.sprintf "%s(%s)" name (String.concat ", " (List.map arg t.arguments))

let to_json t =
  let argument a =
    `Assoc
      ((("role", `String a.role) :: (match a.semantic_type with Some ty -> [ ("semantic_type", `String ty) ] | None -> [])))
  in
  `Assoc
    ((("arguments", `List (List.map argument t.arguments))
     :: (match t.description with Some d -> [ ("description", `String d) ] | None -> [])))

let of_json = function
  | `Assoc fields -> (
      let argument = function
        | `Assoc a -> (
            match (List.assoc_opt "role" a, List.assoc_opt "semantic_type" a) with
            | Some (`String role), (None | Some `Null) -> Ok { role; semantic_type = None }
            | Some (`String role), Some (`String ty) -> Ok { role; semantic_type = Some ty }
            | _ -> Error "Invalid declaration argument JSON")
        | _ -> Error "Invalid declaration argument JSON"
      in
      let description =
        match List.assoc_opt "description" fields with
        | Some (`String d) -> Ok (Some d)
        | None | Some `Null -> Ok None
        | Some _ -> Error "Invalid declaration description JSON"
      in
      match (List.assoc_opt "arguments" fields, description) with
      | Some (`List args), Ok description -> (
          let rec collect acc = function
            | [] -> Ok (List.rev acc)
            | j :: rest -> ( match argument j with Ok a -> collect (a :: acc) rest | Error _ as e -> e)
          in
          match collect [] args with Ok arguments -> make ~arguments ~description | Error _ as e -> e)
      | _, (Error _ as e) -> e
      | _ -> Error "Invalid declaration JSON")
  | _ -> Error "Invalid declaration JSON"
