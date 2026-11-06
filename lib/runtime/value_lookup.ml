(** See {!Value_lookup} (mli) for documentation. *)

let max_text_length = 2000
let max_name_words = 8
let max_partial_candidates = 50
let min_fuzzy_length = 5

let parse_value text =
  match Lexer.tokenize (String.trim text) with
  | Error e -> Error e
  | Ok [] -> Error "Empty value."
  | Ok [ token ] -> Lexer.value_of_token token
  | Ok _ -> Error "Expected a single literal, e.g. judith_goddard, \"Hey Bud\" or @1979."

(* ---- Words ---- *)

type word = { word : string; start : int; stop : int }

let is_word_char c = match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true | c -> Char.code c >= 128

(* Splits [text] into lowercased words with their byte offsets. Bytes from
   U+0080 on are word characters (so accented letters stay inside words),
   except the General Punctuation block U+2000-U+203F (E2 80 xx: curly
   quotes, dashes), which separates words. A possessive 's is dropped. *)
let words text =
  let n = String.length text in
  let separator_width j =
    if j + 2 < n && text.[j] = '\xe2' && text.[j + 1] = '\x80' then 3 else if is_word_char text.[j] then 0 else 1
  in
  let apostrophe_width j =
    if j < n && text.[j] = '\'' then 1
    else if j + 2 < n && text.[j] = '\xe2' && text.[j + 1] = '\x80' && text.[j + 2] = '\x99' then 3
    else 0
  in
  let out = ref [] and i = ref 0 in
  while !i < n do
    let w = separator_width !i in
    if w > 0 then i := !i + w
    else (
      let start = !i in
      while !i < n && separator_width !i = 0 do
        incr i
      done;
      out := { word = String.lowercase_ascii (String.sub text start (!i - start)); start; stop = !i } :: !out;
      let a = apostrophe_width !i in
      let j = !i + a in
      if a > 0 && j < n && (text.[j] = 's' || text.[j] = 'S') && (j + 1 >= n || separator_width (j + 1) > 0) then i := j + 1)
  done;
  List.rev !out

let is_number w = String.for_all (function '0' .. '9' -> true | _ -> false) w
let significant w = String.length w >= 3 && not (is_number w)

(* A capitalised word that does not start a sentence: a cue that it is (part
   of) a name, which a partial match needs. *)
let name_cue text (w : word) =
  let c = text.[w.start] in
  c >= 'A' && c <= 'Z'
  &&
  let rec previous j = if j < 0 then None else match text.[j] with ' ' | '\t' | '"' | '(' | '\'' -> previous (j - 1) | c -> Some c in
  match previous (w.start - 1) with None | Some ('.' | '!' | '?' | ':' | '\n' | '\r') -> false | Some _ -> true

let edit_distance a b =
  let la = String.length a and lb = String.length b in
  let prev = Array.init (lb + 1) Fun.id and cur = Array.make (lb + 1) 0 in
  for i = 1 to la do
    cur.(0) <- i;
    for j = 1 to lb do
      let cost = if a.[i - 1] = b.[j - 1] then 0 else 1 in
      cur.(j) <- min (min (prev.(j) + 1) (cur.(j - 1) + 1)) (prev.(j - 1) + cost)
    done;
    Array.blit cur 0 prev 0 (lb + 1)
  done;
  prev.(lb)

(* Edits allowed for a fuzzy match of a span of [length] bytes. *)
let fuzzy_budget length = if length < min_fuzzy_length then 0 else if length < 9 then 1 else if length < 16 then 2 else 3

(* ---- Values and names ---- *)

let value_key (v : Value.t) = Value.type_name v ^ ":" ^ Value.canonical_string v
let value_text : Value.t -> string option = function Atom s | String s -> Some s | Lang_string { value; _ } -> Some value | _ -> None
let indexable (v : Value.t) = Option.is_some (value_text v)

type kind = Own | Label | Alias

let kind_name = function Own -> "exact" | Label -> "label" | Alias -> "alias"

(* The conventional naming predicates: label(Thing, Name), alias(Thing, Name). *)
let naming_kind (p : Query_environment.predicate_signature) =
  if p.arity <> 2 then None else match p.name with "label" -> Some Label | "alias" -> Some Alias | _ -> None

(* A plain label first, then an English one, then any. *)
let best_label labels =
  let english = function
    | Value.Lang_string { language; _ } ->
        let l = String.lowercase_ascii language in
        l = "en" || String.starts_with ~prefix:"en-" l
    | _ -> false
  in
  let pick =
    match List.find_opt (function Value.String _ | Atom _ -> true | _ -> false) labels with
    | Some l -> Some l
    | None -> ( match List.find_opt english labels with Some l -> Some l | None -> List.nth_opt labels 0)
  in
  Option.bind pick value_text

let sort_values l = List.sort_uniq (fun a b -> compare (value_key a) (value_key b)) l

let role_fields (env : Query_environment.t) predicate position =
  match Query_environment.find env predicate with
  | None -> []
  | Some p -> (
      match List.nth_opt p.arguments position with
      | None -> []
      | Some a ->
          (match a.role with Some r -> [ ("role", `String r) ] | None -> [])
          @ match a.semantic_type with Some t -> [ ("semanticType", `String t) ] | None -> [])

module Make (Store : Runtime_store.S) = struct
  let ( let* ) = Lwt.bind

  type entry = {
    value : Value.t;
    mutable sites : (string * int) list;
    mutable facts : int;
    mutable labels : Value.t list;
    mutable aliases : Value.t list;
  }

  type name = { words : string array; entry : string; kind : kind; display : string }

  type index = {
    entries : (string, entry) Hashtbl.t;
    names : (string, name list) Hashtbl.t;  (** words joined by spaces -> names *)
    by_prefix : (string, string) Hashtbl.t;  (** first 3 bytes of a name's first word -> name keys *)
    by_word : (string, string) Hashtbl.t;  (** any word of a name -> name keys *)
  }

  let add_name idx entry kind text =
    let ws = Array.of_list (List.map (fun w -> w.word) (words text)) in
    let n = Array.length ws in
    if n > 0 && n <= max_name_words then (
      let key = String.concat " " (Array.to_list ws) in
      let existing = Option.value (Hashtbl.find_opt idx.names key) ~default:[] in
      if existing = [] then (
        if String.length ws.(0) >= 3 then Hashtbl.add idx.by_prefix (String.sub ws.(0) 0 3) key;
        List.iter (fun w -> Hashtbl.add idx.by_word w key) (List.sort_uniq String.compare (Array.to_list ws)));
      if not (List.exists (fun nm -> nm.entry = entry && nm.kind = kind) existing) then
        Hashtbl.replace idx.names key ({ words = ws; entry; kind; display = text } :: existing))

  let build_index store (env : Query_environment.t) =
    let idx = { entries = Hashtbl.create 4096; names = Hashtbl.create 4096; by_prefix = Hashtbl.create 1024; by_word = Hashtbl.create 4096 } in
    let entry v =
      let k = value_key v in
      match Hashtbl.find_opt idx.entries k with
      | Some e -> e
      | None ->
          let e = { value = v; sites = []; facts = 0; labels = []; aliases = [] } in
          Hashtbl.replace idx.entries k e;
          e
    in
    let* () =
      Lwt_list.iter_s
        (fun (p : Query_environment.predicate_signature) ->
          let* facts = Store.query_all store p.name in
          let naming = naming_kind p in
          Lwt_list.iteri_s
            (fun n (f : Fact.t) ->
              (match (naming, f.arguments) with
              | Some kind, [ subject; name ] when indexable name -> (
                  let e = entry subject in
                  match kind with Label -> e.labels <- name :: e.labels | _ -> e.aliases <- name :: e.aliases)
              | Some _, _ -> ()
              | None, args ->
                  let seen = Hashtbl.create 4 in
                  List.iteri
                    (fun i v ->
                      if indexable v then (
                        let e = entry v in
                        if not (List.mem (p.name, i) e.sites) then e.sites <- (p.name, i) :: e.sites;
                        let k = value_key v in
                        if not (Hashtbl.mem seen k) then (
                          Hashtbl.replace seen k ();
                          e.facts <- e.facts + 1)))
                    args);
              if n mod 1000 = 999 then Lwt.pause () else Lwt.return_unit)
            facts)
        env.predicates
    in
    Hashtbl.iter
      (fun k e ->
        e.sites <- List.sort compare e.sites;
        e.labels <- sort_values e.labels;
        e.aliases <- sort_values e.aliases;
        Option.iter (add_name idx k Own) (value_text e.value);
        List.iter (fun l -> Option.iter (add_name idx k Label) (value_text l)) e.labels;
        List.iter (fun l -> Option.iter (add_name idx k Alias) (value_text l)) e.aliases)
      idx.entries;
    Lwt.return idx

  (* ---- resolve ---- *)

  type candidate = { c_entry : entry; c_name : name; c_match : string; c_rank : int }

  let candidate_json env c =
    let e = c.c_entry in
    `Assoc
      ([
         ("value", Value.to_json e.value);
         ("literal", `String (Query_diagnostics.dsl_literal e.value));
         ("matchedName", `String c.c_name.display);
         ("match", `String c.c_match);
       ]
      @ (match best_label e.labels with Some l -> [ ("label", `String l) ] | None -> [])
      @ [
          ("facts", `Int e.facts);
          ( "occurs",
            `List
              (List.map
                 (fun (predicate, position) ->
                   `Assoc ([ ("predicate", `String predicate); ("position", `Int position) ] @ role_fields env predicate position))
                 e.sites) );
        ])

  (* One candidate per value, keeping its best-ranked name. *)
  let distinct candidates =
    let best = Hashtbl.create 16 in
    List.iter
      (fun c ->
        let k = c.c_name.entry in
        match Hashtbl.find_opt best k with Some b when b.c_rank <= c.c_rank -> () | _ -> Hashtbl.replace best k c)
      candidates;
    Hashtbl.fold (fun _ c acc -> c :: acc) best []
    |> List.sort (fun a b ->
           compare (a.c_rank, -a.c_entry.facts, value_key a.c_entry.value) (b.c_rank, -b.c_entry.facts, value_key b.c_entry.value))

  let names_with_key idx key = Option.value (Hashtbl.find_opt idx.names key) ~default:[]

  let exact idx entries key =
    List.map
      (fun nm -> { c_entry = Hashtbl.find entries nm.entry; c_name = nm; c_match = kind_name nm.kind; c_rank = (match nm.kind with Own -> 0 | Label -> 1 | Alias -> 2) })
      (names_with_key idx key)

  let fuzzy idx span =
    let key = String.concat " " (Array.to_list span) in
    (* Each word is compared on its own, so short words must match exactly
       ("about tate" is not "about time"). *)
    let close (ws : string array) =
      if Array.length ws <> Array.length span then None
      else
        let total = ref 0 and ok = ref true in
        Array.iteri
          (fun k w ->
            if !ok && w <> span.(k) then
              let budget = fuzzy_budget (String.length span.(k)) in
              if budget = 0 || abs (String.length w - String.length span.(k)) > budget then ok := false
              else
                let d = edit_distance span.(k) w in
                if d > budget then ok := false else total := !total + d)
          ws;
        if !ok && !total > 0 then Some !total else None
    in
    if String.length span.(0) < 3 then []
    else
      let keys = List.sort_uniq String.compare (Hashtbl.find_all idx.by_prefix (String.sub span.(0) 0 3)) in
      let scored =
        List.filter_map
          (fun k ->
            if k = key then None
            else match names_with_key idx k with [] -> None | nm :: _ -> Option.map (fun d -> (d, k)) (close nm.words))
          keys
      in
      match List.sort compare scored with
      | [] -> []
      | (d, _) :: _ ->
          List.concat_map
            (fun (d', k) ->
              if d' <> d then []
              else List.map (fun nm -> { c_entry = Hashtbl.find idx.entries nm.entry; c_name = nm; c_match = "fuzzy"; c_rank = 10 + d }) (names_with_key idx k))
            scored

  (* Names that contain [span] as a contiguous run of words and are longer. *)
  let partial idx span =
    let n = Array.length span in
    if not (significant span.(0) && significant span.(n - 1)) then []
    else
      let contains (ws : string array) =
        let m = Array.length ws in
        m > n
        &&
        let rec at i = i + n <= m && ((let ok = ref true in Array.iteri (fun k w -> if ws.(i + k) <> w then ok := false) span; !ok) || at (i + 1)) in
        at 0
      in
      (* The rarest word bounds the candidates. *)
      let postings w = List.sort_uniq String.compare (Hashtbl.find_all idx.by_word w) in
      let shortest =
        Array.fold_left
          (fun acc w -> let p = postings w in match acc with Some q when List.length q <= List.length p -> acc | _ -> Some p)
          None span
      in
      Option.value shortest ~default:[]
      |> List.concat_map (fun k -> names_with_key idx k)
      |> List.filter (fun nm -> contains nm.words)
      |> List.map (fun nm -> { c_entry = Hashtbl.find idx.entries nm.entry; c_name = nm; c_match = "partial"; c_rank = 20 })

  let resolve ?(max_candidates = 10) env idx text =
    if String.length text > max_text_length then
      Error ("text_too_long", Printf.sprintf "Text is too long: %d bytes (maximum %d)." (String.length text) max_text_length)
    else
      let ws = Array.of_list (words text) in
      let n = Array.length ws in
      let covered = Array.make n false in
      let mentions = ref [] in
      for len = min n max_name_words downto 1 do
        for i = 0 to n - len do
          let free = ref true in
          for k = i to i + len - 1 do
            if covered.(k) then free := false
          done;
          if !free && (len > 1 || significant ws.(i).word) then (
            let span = Array.init len (fun k -> ws.(i + k).word) in
            let key = String.concat " " (Array.to_list span) in
            let partial_ok () = len = n || List.exists (fun k -> name_cue text ws.(k)) (List.init len (fun k -> i + k)) in
            let found =
              match exact idx idx.entries key with
              | _ :: _ as l -> l
              | [] -> ( match fuzzy idx span with _ :: _ as l -> l | [] -> if partial_ok () then partial idx span else [])
            in
            let candidates = distinct found in
            let count = List.length candidates in
            let too_vague = count > max_partial_candidates && List.for_all (fun c -> c.c_match = "partial") candidates in
            if count > 0 && not too_vague then (
              for k = i to i + len - 1 do
                covered.(k) <- true
              done;
              mentions := (i, len, candidates) :: !mentions))
        done
      done;
      let mention (i, len, candidates) =
        let start = ws.(i).start and stop = ws.(i + len - 1).stop in
        `Assoc
          [
            ("text", `String (String.sub text start (stop - start)));
            ("start", `Int start);
            ("end", `Int stop);
            ("match", `String (List.hd candidates).c_match);
            ("candidateCount", `Int (List.length candidates));
            ("candidates", `List (List.map (candidate_json env) (List.filteri (fun k _ -> k < max_candidates) candidates)));
          ]
      in
      let ordered = List.sort (fun (a, _, _) (b, _, _) -> compare a b) !mentions in
      Ok (`Assoc [ ("text", `String text); ("mentions", `List (List.map mention ordered)) ])

  (* ---- about ---- *)

  let fact_order (a : Fact.t) (b : Fact.t) = compare (List.map value_key a.arguments) (List.map value_key b.arguments)

  let about ?(limit = 20) store (env : Query_environment.t) (v : Value.t) =
    let limit = max 0 limit in
    let type_name = Value.type_name v in
    let seen = Hashtbl.create 64 in
    let labels = ref [] and aliases = ref [] in
    let* groups =
      Lwt_list.fold_left_s
        (fun acc (p : Query_environment.predicate_signature) ->
          match naming_kind p with
          | Some kind ->
              let first = List.nth_opt p.arguments 0 in
              if not (match first with Some a -> List.mem type_name a.types | None -> false) then Lwt.return acc
              else
                let* facts = Store.equality_lookup store p.name 0 v in
                let names = List.filter_map (fun (f : Fact.t) -> match f.arguments with [ _; nm ] when indexable nm -> Some nm | _ -> None) facts in
                (match kind with Label -> labels := names @ !labels | _ -> aliases := names @ !aliases);
                Lwt.return acc
          | None ->
              Lwt_list.fold_left_s
                (fun acc (a : Query_environment.argument_signature) ->
                  if not (List.mem type_name a.types) then Lwt.return acc
                  else
                    let* facts = Store.equality_lookup store p.name a.position v in
                    if facts = [] then Lwt.return acc
                    else (
                      List.iter (fun f -> Hashtbl.replace seen (Fact.encode f) ()) facts;
                      let facts = List.sort fact_order facts in
                      let count = List.length facts in
                      let roles =
                        if p.arguments <> [] && List.for_all (fun (x : Query_environment.argument_signature) -> x.role <> None) p.arguments then
                          `List (List.map (fun (x : Query_environment.argument_signature) -> `String (Option.get x.role)) p.arguments)
                        else `Null
                      in
                      let group =
                        `Assoc
                          ([ ("predicate", `String p.name); ("position", `Int a.position) ]
                          @ (match p.description with Some d -> [ ("description", `String d) ] | None -> [])
                          @ [
                              ("roles", roles);
                              ("count", `Int count);
                              ( "facts",
                                `List
                                  (List.filteri (fun k _ -> k < limit) facts
                                  |> List.map (fun (f : Fact.t) -> `List (List.map Value.to_json f.arguments))) );
                              ("hasMore", `Bool (count > limit));
                            ])
                      in
                      Lwt.return (group :: acc)))
                acc p.arguments)
        [] env.predicates
    in
    let labels = sort_values !labels and aliases = sort_values !aliases in
    Lwt.return
      (`Assoc
        ([ ("value", Value.to_json v); ("literal", `String (Query_diagnostics.dsl_literal v)) ]
        @ (match best_label labels with Some l -> [ ("label", `String l) ] | None -> [])
        @ [
            ("aliases", `List (List.filter_map (fun a -> Option.map (fun s -> `String s) (value_text a)) aliases));
            ("facts", `Int (Hashtbl.length seen));
            ("predicates", `List (List.rev groups));
          ]))
end
