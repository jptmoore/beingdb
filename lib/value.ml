(** See {!Value} (mli) for documentation. *)

type t =
  | Atom of string
  | String of string
  | Lang_string of { value : string; language : string }
  | Integer of int64
  | Decimal of Decimal.t
  | Boolean of bool
  | Year of int
  | Year_month of { year : int; month : int }
  | Date of { year : int; month : int; day : int }
  | Instant of Calendar.instant
  | Uri of string

let type_name = function
  | Atom _ -> "atom"
  | String _ -> "string"
  | Lang_string _ -> "lang_string"
  | Integer _ -> "integer"
  | Decimal _ -> "decimal"
  | Boolean _ -> "boolean"
  | Year _ -> "year"
  | Year_month _ -> "year_month"
  | Date _ -> "date"
  | Instant _ -> "instant"
  | Uri _ -> "uri"

(* Basic BCP-47-ish validation: primary subtag of 2-8 letters, followed by
   any number of 1-8 alphanumeric subtags separated by '-'. This is a
   "reasonable degree" of validation, not a full BCP 47 parser. *)
let valid_language_tag tag =
  let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') in
  let is_alnum c = is_alpha c || (c >= '0' && c <= '9') in
  let subtags = String.split_on_char '-' tag in
  match subtags with
  | [] -> false
  | primary :: rest ->
      let len = String.length primary in
      (len >= 2 && len <= 8 && String.for_all is_alpha primary)
      && List.for_all
           (fun s ->
             let l = String.length s in
             l >= 1 && l <= 8 && String.for_all is_alnum s)
           rest

let make_lang_string ~value ~language =
  if valid_language_tag language then Ok (Lang_string { value; language })
  else Error (Printf.sprintf "Invalid language tag: %s" language)

let make_year_month ~year ~month =
  if Calendar.valid_year_month ~year ~month then Ok (Year_month { year; month })
  else Error (Printf.sprintf "Invalid year-month: %04d-%02d" year month)

let make_date ~year ~month ~day =
  if Calendar.valid_date ~year ~month ~day then Ok (Date { year; month; day })
  else Error (Printf.sprintf "Invalid date: %04d-%02d-%02d" year month day)

(* Minimal but meaningful URI validation: <scheme>:<scheme-specific-part>
   with no whitespace or angle brackets, per RFC 3986 scheme syntax. *)
let valid_uri s =
  if s = "" || String.contains s ' ' || String.contains s '<'
     || String.contains s '>' || String.contains s '\t'
     || String.contains s '\n'
  then false
  else
    match String.index_opt s ':' with
    | None -> false
    | Some colon when colon = 0 -> false
    | Some colon ->
        let scheme = String.sub s 0 colon in
        let is_scheme_char i c =
          if i = 0 then (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
          else
            (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c = '+' || c = '-' || c = '.'
        in
        String.length scheme > 0
        && (let ok = ref true in
            String.iteri (fun i c -> if not (is_scheme_char i c) then ok := false) scheme;
            !ok)
        && colon + 1 < String.length s

let make_uri s = if valid_uri s then Ok (Uri s) else Error (Printf.sprintf "Malformed URI: %s" s)

let equal a b =
  match (a, b) with
  | Atom a, Atom b -> String.equal a b
  | String a, String b -> String.equal a b
  | Lang_string a, Lang_string b -> String.equal a.value b.value && String.equal a.language b.language
  | Integer a, Integer b -> Int64.equal a b
  | Decimal a, Decimal b -> Decimal.equal a b
  | Boolean a, Boolean b -> Bool.equal a b
  | Year a, Year b -> Int.equal a b
  | Year_month a, Year_month b -> a.year = b.year && a.month = b.month
  | Date a, Date b -> a.year = b.year && a.month = b.month && a.day = b.day
  | Instant a, Instant b -> Calendar.equal_instant a b
  | Uri a, Uri b -> String.equal a b
  | _ -> false

let canonical_string = function
  | Atom s -> s
  | String s -> s
  | Lang_string { value; language } -> value ^ "@" ^ language
  | Integer n -> Int64.to_string n
  | Decimal d -> Decimal.to_string d
  | Boolean b -> if b then "true" else "false"
  | Year y -> Calendar.format_year y
  | Year_month { year; month } -> Calendar.format_year_month ~year ~month
  | Date { year; month; day } -> Calendar.format_date ~year ~month ~day
  | Instant t -> Calendar.format_instant t
  | Uri s -> s

let sortable_string = function
  | Integer n -> Some (Printf.sprintf "%020Lu" (Int64.logxor n Int64.min_int))
  | Decimal d -> Some (Decimal.to_sortable_string d)
  | Year y -> Some (Calendar.year_sortable_string y)
  | Year_month { year; month } -> Some (Calendar.year_month_sortable_string ~year ~month)
  | Date { year; month; day } -> Some (Calendar.date_sortable_string ~year ~month ~day)
  | Instant t -> Some (Calendar.instant_sortable_string t)
  | Atom _ | String _ | Lang_string _ | Boolean _ | Uri _ -> None

let is_ordered_type = function
  | Integer _ | Decimal _ | Year _ | Year_month _ | Date _ | Instant _ -> true
  | Atom _ | String _ | Lang_string _ | Boolean _ | Uri _ -> false

let max_inline_key_length = 200

let index_key v =
  let s = match sortable_string v with Some k -> k | None -> canonical_string v in
  if String.length s <= max_inline_key_length then s
  else "h:" ^ Digest.to_hex (Digest.string s)

(* Ordering is only defined for compatible types; Integer/Decimal support
   numeric promotion. All other types (atoms, strings, lang-strings,
   booleans, URIs) support equality only, not ordering, in this first
   implementation. *)
let order_error a b =
  let hint =
    match (a, b) with
    | Year y, Date d | Date d, Year y ->
        Printf.sprintf "\n\nDid you mean @%04d (year only) or @%04d-%02d-%02d (full date)?"
          y d.year d.month d.day
    | _ -> ""
  in
  Error
    (Printf.sprintf "Cannot compare a %s with a %s.\n\nLeft value: %s\nRight value: %s%s"
       (type_name a) (type_name b) (canonical_string a) (canonical_string b) hint)

let order_compare a b =
  match (a, b) with
  | Integer a, Integer b -> Ok (Int64.compare a b)
  | Decimal a, Decimal b -> Ok (Decimal.compare a b)
  | Integer a, Decimal b -> Ok (Decimal.compare (Decimal.make a 0) b)
  | Decimal a, Integer b -> Ok (Decimal.compare a (Decimal.make b 0))
  (* A bare integer literal is commonly used to compare against a Year
     (e.g. [Year >= 1900]); this is a deliberate, narrow promotion (unlike
     Year<->Date, which is never promoted). *)
  | Year a, Integer b -> Ok (compare a (Int64.to_int b))
  | Integer a, Year b -> Ok (compare (Int64.to_int a) b)
  | Year a, Year b -> Ok (compare a b)
  | Year_month a, Year_month b -> Ok (compare (a.year, a.month) (b.year, b.month))
  | Date a, Date b -> Ok (compare (a.year, a.month, a.day) (b.year, b.month, b.day))
  | Instant a, Instant b -> Ok (Calendar.compare_instant a b)
  | _ -> order_error a b

let to_json v =
  `Assoc [ ("type", `String (type_name v)); ("value", `String (canonical_string v)) ]

let of_canonical ~type_name s =
  match type_name with
  | "atom" -> Ok (Atom s)
  | "string" -> Ok (String s)
  | "lang_string" -> (
      match String.rindex_opt s '@' with
      | None -> Error (Printf.sprintf "Invalid lang_string encoding: %s" s)
      | Some idx ->
          make_lang_string
            ~value:(String.sub s 0 idx)
            ~language:(String.sub s (idx + 1) (String.length s - idx - 1)))
  | "integer" -> (
      match Int64.of_string_opt s with
      | Some n -> Ok (Integer n)
      | None -> Error (Printf.sprintf "Invalid integer encoding: %s" s))
  | "decimal" -> ( match Decimal.of_string s with Ok d -> Ok (Decimal d) | Error e -> Error e )
  | "boolean" -> (
      match s with
      | "true" -> Ok (Boolean true)
      | "false" -> Ok (Boolean false)
      | _ -> Error (Printf.sprintf "Invalid boolean encoding: %s" s))
  | "year" -> ( match Calendar.parse_year s with Ok y -> Ok (Year y) | Error e -> Error e )
  | "year_month" -> (
      match Calendar.parse_year_month s with
      | Ok (year, month) -> make_year_month ~year ~month
      | Error e -> Error e)
  | "date" -> (
      match Calendar.parse_date s with
      | Ok (year, month, day) -> make_date ~year ~month ~day
      | Error e -> Error e)
  | "instant" -> ( match Calendar.parse_instant s with Ok t -> Ok (Instant t) | Error e -> Error e )
  | "uri" -> make_uri s
  | other -> Error (Printf.sprintf "Unknown value type tag: %s" other)
