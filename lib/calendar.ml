(** See {!Calendar} (mli) for documentation. *)

let is_leap_year y = (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0

let days_in_month y m =
  match m with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
  | 4 | 6 | 9 | 11 -> 30
  | 2 -> if is_leap_year y then 29 else 28
  | _ -> 0

let valid_date ~year ~month ~day =
  month >= 1 && month <= 12 && day >= 1 && day <= days_in_month year month

let valid_year_month ~year:_ ~month = month >= 1 && month <= 12

(* Howard Hinnant's days-from-civil / civil-from-days algorithm for the
   proleptic Gregorian calendar. See http://howardhinnant.github.io/date_algorithms.html *)

let days_from_civil ~year ~month ~day =
  let y = if month <= 2 then year - 1 else year in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - era * 400 in
  (* [0, 399] *)
  let mp = if month > 2 then month - 3 else month + 9 in
  let doy = ((153 * mp) + 2) / 5 + day - 1 in
  (* [0, 365] *)
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (* [0, 146096] *)
  Int64.sub
    (Int64.add (Int64.mul (Int64.of_int era) 146097L) (Int64.of_int doe))
    719468L

let civil_from_days z =
  let z = Int64.add z 719468L in
  let era =
    Int64.to_int
      (Int64.div (if z >= 0L then z else Int64.sub z 146096L) 146097L)
  in
  let doe = Int64.to_int (Int64.sub z (Int64.mul (Int64.of_int era) 146097L)) in
  (* [0, 146096] *)
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  (* [0, 399] *)
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  (* [0, 365] *)
  let mp = ((5 * doy) + 2) / 153 in
  (* [0, 11] *)
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  (* [1, 31] *)
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let y = if m <= 2 then y + 1 else y in
  (y, m, d)

type instant = { seconds : int64; nanos : int }

let compare_instant a b =
  let c = Int64.compare a.seconds b.seconds in
  if c <> 0 then c else Stdlib.compare a.nanos b.nanos

let equal_instant a b = compare_instant a b = 0

let sortable_int64 v = Printf.sprintf "%020Lu" (Int64.logxor v Int64.min_int)

let instant_sortable_string t =
  Printf.sprintf "%s.%09d" (sortable_int64 t.seconds) t.nanos

let date_sortable_string ~year ~month ~day =
  sortable_int64 (days_from_civil ~year ~month ~day)

let year_sortable_string y = sortable_int64 (Int64.of_int y)

let year_month_sortable_string ~year ~month =
  sortable_int64 (Int64.of_int ((year * 100) + month))

let is_digit c = c >= '0' && c <= '9'

let all_digits s = s <> "" && String.for_all is_digit s

let parse_int_exn s = int_of_string s

let split_sign s =
  if String.length s > 0 && s.[0] = '-' then
    (true, String.sub s 1 (String.length s - 1))
  else (false, s)

let parse_year s =
  let negative, rest = split_sign s in
  if not (all_digits rest) then
    Error (Printf.sprintf "Invalid year literal: %s" s)
  else
    let y = parse_int_exn rest in
    Ok (if negative then -y else y)

let parse_year_month s =
  match String.split_on_char '-' s with
  | [ y; m ] when all_digits m && String.length m = 2 ->
      (match parse_year y with
       | Error _ as e -> e
       | Ok year ->
           let month = parse_int_exn m in
           if valid_year_month ~year ~month then Ok (year, month)
           else Error (Printf.sprintf "Invalid year-month literal: %s" s))
  | [ ""; y; m ] when all_digits m && String.length m = 2 ->
      (* negative year: "-0500-06" splits into ["";"0500";"06"] *)
      (match parse_year ("-" ^ y) with
       | Error _ as e -> e
       | Ok year ->
           let month = parse_int_exn m in
           if valid_year_month ~year ~month then Ok (year, month)
           else Error (Printf.sprintf "Invalid year-month literal: %s" s))
  | _ -> Error (Printf.sprintf "Invalid year-month literal: %s" s)

let parse_date s =
  let parts = String.split_on_char '-' s in
  let year_str, month_str, day_str =
    match parts with
    | [ y; m; d ] -> (y, m, d)
    | [ ""; y; m; d ] -> ("-" ^ y, m, d)
    | _ -> ("", "", "")
  in
  if
    month_str = "" || day_str = "" || not (all_digits month_str)
    || not (all_digits day_str)
    || String.length month_str <> 2 || String.length day_str <> 2
  then Error (Printf.sprintf "Invalid date literal: %s" s)
  else
    match parse_year year_str with
    | Error _ -> Error (Printf.sprintf "Invalid date literal: %s" s)
    | Ok year ->
        let month = parse_int_exn month_str in
        let day = parse_int_exn day_str in
        if valid_date ~year ~month ~day then Ok (year, month, day)
        else Error (Printf.sprintf "Invalid date literal: %s" s)

(** Parse ["YYYY-MM-DDTHH:MM:SS"] plus optional fraction and zone. *)
let parse_instant s =
  match String.index_opt s 'T' with
  | None -> Error (Printf.sprintf "Invalid instant literal (missing 'T'): %s" s)
  | Some t_pos ->
      let date_part = String.sub s 0 t_pos in
      let rest = String.sub s (t_pos + 1) (String.length s - t_pos - 1) in
      (match parse_date date_part with
       | Error _ -> Error (Printf.sprintf "Invalid instant literal: %s" s)
       | Ok (year, month, day) ->
           (* find zone designator: 'Z' or +/-HH:MM, searched from the end *)
           let len = String.length rest in
           let zone_start =
             if len > 0 && rest.[len - 1] = 'Z' then Some (len - 1)
             else
               (* look for +HH:MM or -HH:MM after the time-of-day, i.e. after
                  position 8 ("HH:MM:SS") to avoid confusing with date sign *)
               let rec find i =
                 if i >= len then None
                 else if (rest.[i] = '+' || rest.[i] = '-') && i >= 8 then Some i
                 else find (i + 1)
               in
               find 0
           in
           (match zone_start with
            | None ->
                Error
                  (Printf.sprintf
                     "Invalid instant literal (missing zone designator, use \
                      Z or +HH:MM): %s"
                     s)
            | Some zpos ->
                let time_part = String.sub rest 0 zpos in
                let zone_part =
                  String.sub rest zpos (len - zpos)
                in
                (match String.split_on_char ':' time_part with
                 | [ hh; mm; ss_frac ] when String.length hh = 2 && String.length mm = 2 ->
                     let ss, frac =
                       match String.index_opt ss_frac '.' with
                       | None -> (ss_frac, "")
                       | Some dot ->
                           ( String.sub ss_frac 0 dot,
                             String.sub ss_frac (dot + 1)
                               (String.length ss_frac - dot - 1) )
                     in
                     if
                       (not (all_digits hh)) || (not (all_digits mm))
                       || String.length ss <> 2 || not (all_digits ss)
                       || (frac <> "" && not (all_digits frac))
                     then Error (Printf.sprintf "Invalid instant literal: %s" s)
                     else
                       let hour = parse_int_exn hh in
                       let minute = parse_int_exn mm in
                       let second = parse_int_exn ss in
                       if hour > 23 || minute > 59 || second > 60 then
                         Error (Printf.sprintf "Invalid instant literal: %s" s)
                       else
                         let nanos =
                           if frac = "" then 0
                           else
                             let frac9 =
                               if String.length frac >= 9 then
                                 String.sub frac 0 9
                               else
                                 frac
                                 ^ String.make (9 - String.length frac) '0'
                             in
                             parse_int_exn frac9
                         in
                         let offset_minutes =
                           if zone_part = "Z" then Some 0
                           else
                             match String.split_on_char ':' zone_part with
                             | [ sign_hh; mm2 ]
                               when String.length sign_hh = 3
                                    && String.length mm2 = 2
                                    && (sign_hh.[0] = '+' || sign_hh.[0] = '-')
                                    && all_digits (String.sub sign_hh 1 2)
                                    && all_digits mm2 ->
                                 let sign =
                                   if sign_hh.[0] = '-' then -1 else 1
                                 in
                                 let oh = parse_int_exn (String.sub sign_hh 1 2) in
                                 let om = parse_int_exn mm2 in
                                 if oh > 23 || om > 59 then None
                                 else Some (sign * ((oh * 60) + om))
                             | _ -> None
                         in
                         (match offset_minutes with
                          | None ->
                              Error
                                (Printf.sprintf
                                   "Invalid instant literal (bad zone \
                                    designator): %s"
                                   s)
                          | Some offset_minutes ->
                              let days = days_from_civil ~year ~month ~day in
                              let local_seconds =
                                Int64.add
                                  (Int64.mul days 86400L)
                                  (Int64.of_int
                                     ((hour * 3600) + (minute * 60) + second))
                              in
                              let utc_seconds =
                                Int64.sub local_seconds
                                  (Int64.of_int (offset_minutes * 60))
                              in
                              Ok { seconds = utc_seconds; nanos })
                 | _ -> Error (Printf.sprintf "Invalid instant literal: %s" s))))

let format_year y = string_of_int y

let format_year_month ~year ~month = Printf.sprintf "%04d-%02d" year month

let format_date ~year ~month ~day = Printf.sprintf "%04d-%02d-%02d" year month day

let format_instant t =
  let seconds_per_day = 86400L in
  let days =
    if Int64.rem t.seconds seconds_per_day < 0L
       && Int64.rem t.seconds seconds_per_day <> 0L
    then Int64.sub (Int64.div t.seconds seconds_per_day) 1L
    else Int64.div t.seconds seconds_per_day
  in
  let secs_of_day =
    Int64.to_int (Int64.sub t.seconds (Int64.mul days seconds_per_day))
  in
  let year, month, day = civil_from_days days in
  let hour = secs_of_day / 3600 in
  let minute = secs_of_day mod 3600 / 60 in
  let second = secs_of_day mod 60 in
  let frac =
    if t.nanos = 0 then ""
    else
      let s = Printf.sprintf "%09d" t.nanos in
      let rec trim i =
        if i <= 1 && s.[i - 1] <> '0' then i
        else if s.[i - 1] = '0' then trim (i - 1)
        else i
      in
      let cut = trim (String.length s) in
      "." ^ String.sub s 0 cut
  in
  Printf.sprintf "%sT%02d:%02d:%02d%sZ" (format_date ~year ~month ~day) hour minute second frac
