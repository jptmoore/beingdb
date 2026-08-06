(** See {!Repl_support} (mli) for documentation. *)

open Lwt.Syntax

type load_kind = Facts | Queries

let load_kind_of_filename path =
  match String.lowercase_ascii (Filename.extension path) with
  | ".pl" | ".pro" | ".facts" -> Facts
  | _ -> Queries

let read_lines path =
  let* lines = Lwt_io.lines_of_file path |> Lwt_stream.to_list in
  Lwt.return lines

let is_significant line =
  let line = String.trim line in
  line <> "" && not (String.starts_with ~prefix:"%" line) && not (String.starts_with ~prefix:"#" line)

let load_facts_file store path =
  Lwt.catch
    (fun () ->
      let* lines = read_lines path in
      let significant = List.filter is_significant lines in
      let parsed = List.map (fun line -> (line, Parse_predicate.parse_fact line)) significant in
      let parse_errors =
        List.filter_map (fun (line, r) -> match r with Some (Error e) -> Some (Printf.sprintf "%s (%s)" line e) | _ -> None) parsed
      in
      let facts =
        List.filter_map (fun (_, r) -> match r with Some (Ok (predicate, args)) -> Some (Fact.make predicate args) | _ -> None) parsed
      in
      if facts = [] then
        Lwt.return
          (Error
             (if parse_errors = [] then Printf.sprintf "No facts found in %s" path
              else Printf.sprintf "No valid facts in %s:\n  %s" path (String.concat "\n  " parse_errors)))
      else
        let by_predicate = Hashtbl.create 8 in
        let order = ref [] in
        List.iter
          (fun (f : Fact.t) ->
            if not (Hashtbl.mem by_predicate f.predicate) then order := f.predicate :: !order;
            let existing = try Hashtbl.find by_predicate f.predicate with Not_found -> [] in
            Hashtbl.replace by_predicate f.predicate (f :: existing))
          facts;
        let predicates = List.rev !order in
        let* summaries =
          Lwt_list.map_s
            (fun predicate ->
              let group = List.rev (Hashtbl.find by_predicate predicate) in
              let arities = List.map (fun (f : Fact.t) -> List.length f.arguments) group |> List.sort_uniq compare in
              match arities with
              | [ _ ] ->
                  let* () =
                    Pack_backend.write_predicate_batch store predicate group
                      (Printf.sprintf "repl :load %s" path)
                  in
                  Lwt.return (Printf.sprintf "%s (%d facts)" predicate (List.length group))
              | _ -> Lwt.return (Printf.sprintf "%s: arity mismatch, not written" predicate))
            predicates
        in
        Lwt.return (Ok (summaries @ List.map (fun e -> "parse error: " ^ e) parse_errors)))
    (fun exn -> Lwt.return (Error (Printf.sprintf "Could not read %s: %s" path (Printexc.to_string exn))))

let run_queries_file ~max_results store path =
  Lwt.catch
    (fun () ->
      let* lines = read_lines path in
      let queries = List.filter is_significant lines in
      Lwt_list.map_s
        (fun query_text ->
          let* result = Controller.execute_query ~max_results store query_text ~offset:None ~limit:None in
          Lwt.return (query_text, result))
        queries)
    (fun exn -> Lwt.return [ (path, Error (Printf.sprintf "Could not read %s: %s" path (Printexc.to_string exn))) ])
