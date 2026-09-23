(** See {!Decimal} (mli) for documentation. *)

type t = { coeff : int64; scale : int }

let make coeff scale =
  if coeff = 0L then { coeff = 0L; scale = 0 }
  else
    let rec strip coeff scale =
      if scale > 0 && Int64.rem coeff 10L = 0L then
        strip (Int64.div coeff 10L) (scale - 1)
      else (coeff, scale)
    in
    let coeff, scale = strip coeff scale in
    { coeff; scale }

let coefficient t = t.coeff
let scale t = t.scale

let is_digit c = c >= '0' && c <= '9'

(** Parse ["-"]? digits (["." digits])? *)
let of_string s =
  let len = String.length s in
  if len = 0 then Error "Empty decimal literal"
  else
    let negative = s.[0] = '-' in
    let start = if negative || s.[0] = '+' then 1 else 0 in
    if start >= len then Error (Printf.sprintf "Invalid decimal literal: %s" s)
    else
      match String.index_from_opt s start '.' with
      | None ->
          let digits = String.sub s start (len - start) in
          if digits = "" || not (String.for_all is_digit digits) then
            Error (Printf.sprintf "Invalid decimal literal: %s" s)
          else
            let text = (if negative then "-" else "") ^ digits in
            (match Int64.of_string_opt text with
             | None -> Error (Printf.sprintf "Decimal literal out of range: %s" s)
             | Some coeff -> Ok (make coeff 0))
      | Some dot_pos ->
          let int_part = String.sub s start (dot_pos - start) in
          let frac_part = String.sub s (dot_pos + 1) (len - dot_pos - 1) in
          if frac_part = "" || not (String.for_all is_digit frac_part) ||
             (int_part <> "" && not (String.for_all is_digit int_part))
          then
            Error (Printf.sprintf "Invalid decimal literal: %s" s)
          else
            let int_part = if int_part = "" then "0" else int_part in
            let digits = int_part ^ frac_part in
            let text = (if negative then "-" else "") ^ digits in
            (match Int64.of_string_opt text with
             | None -> Error (Printf.sprintf "Decimal literal out of range: %s" s)
             | Some coeff -> Ok (make coeff (String.length frac_part)))

let to_string t =
  let sign = if t.coeff < 0L then "-" else "" in
  let digits = Int64.to_string (Int64.abs t.coeff) in
  if t.scale = 0 then sign ^ digits
  else
    let digits =
      if String.length digits <= t.scale then
        String.make (t.scale - String.length digits + 1) '0' ^ digits
      else digits
    in
    let cut = String.length digits - t.scale in
    let int_part = String.sub digits 0 cut in
    let frac_part = String.sub digits cut t.scale in
    sign ^ int_part ^ "." ^ frac_part

let strip_leading_zeros s =
  let len = String.length s in
  let i = ref 0 in
  while !i < len - 1 && s.[!i] = '0' do incr i done;
  String.sub s !i (len - !i)

let compare_nonneg_digit_strings s1 s2 =
  let s1 = strip_leading_zeros s1 and s2 = strip_leading_zeros s2 in
  let l1 = String.length s1 and l2 = String.length s2 in
  if l1 <> l2 then compare l1 l2 else String.compare s1 s2

(** Non-negative digit string of [t] at scale [target_scale >= t.scale]. *)
let digits_at t target_scale =
  let digits = Int64.to_string (Int64.abs t.coeff) in
  let pad = target_scale - t.scale in
  digits ^ String.make pad '0'

let sign_of t = if t.coeff < 0L then -1 else if t.coeff > 0L then 1 else 0

let compare a b =
  let sa = sign_of a and sb = sign_of b in
  if sa <> sb then Stdlib.compare sa sb
  else if sa = 0 then 0
  else
    let target_scale = max a.scale b.scale in
    let da = digits_at a target_scale and db = digits_at b target_scale in
    let mag = compare_nonneg_digit_strings da db in
    if sa >= 0 then mag else -mag

let equal a b = compare a b = 0

let sortable_scale = 18

let checked_scale_up coeff diff =
  let rec loop c n =
    if n <= 0 then c
    else if c > 0L then
      (if c > Int64.div Int64.max_int 10L then Int64.max_int
       else loop (Int64.mul c 10L) (n - 1))
    else if c < 0L then
      (if c < Int64.div Int64.min_int 10L then Int64.min_int
       else loop (Int64.mul c 10L) (n - 1))
    else 0L
  in
  loop coeff diff

let scale_down coeff diff =
  let rec loop c n = if n <= 0 then c else loop (Int64.div c 10L) (n - 1) in
  loop coeff diff

let to_sortable_string t =
  let diff = sortable_scale - t.scale in
  let rescaled =
    if diff >= 0 then checked_scale_up t.coeff diff
    else scale_down t.coeff (-diff)
  in
  Printf.sprintf "%020Lu" (Int64.logxor rescaled Int64.min_int)
