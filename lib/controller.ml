(** Controller: Business logic layer for query execution and validation *)

open Lwt.Infix

(** Convert fact arguments to typed JSON: a list of [{"type":..,"value":..}]. *)
let fact_to_json (args : Value.t list) = `List (List.map Value.to_json args)

(** List predicates with optional samples *)
let list_predicates ~samples store =
  match samples with
  | None ->
      Model.list_predicates store
      >>= fun predicates ->
      let predicates_json = List.map (fun pred ->
        `Assoc [
          "name", `String pred.Model.name;
          "arity", `Int pred.Model.arity
        ]
      ) predicates in
      let json = `Assoc [
        "predicates", `List predicates_json
      ] in
      Lwt.return (Ok json)
  | Some limit ->
      Model.list_predicates_with_samples ~samples:limit store
      >>= fun predicates ->
      let predicates_json = List.map (fun pred ->
        let base = [
          "name", `String pred.Model.name;
          "arity", `Int pred.Model.arity
        ] in
        match pred.Model.sample_facts with
        | None -> `Assoc base
        | Some sample_facts ->
            `Assoc (base @ [
              "samples", `List (List.map (fun (f : Fact.t) -> fact_to_json f.arguments) sample_facts);
              "sample_count", `Int (List.length sample_facts)
            ])
      ) predicates in
      let json = `Assoc [
        "predicates", `List predicates_json;
        "samples_per_predicate", `Int limit
      ] in
      Lwt.return (Ok json)

(** List predicates with full schema detail (argument type signatures,
    fact counts, bounded examples) and the query-environment fingerprint,
    for programmatic/LLM discovery of the dataset's shape. Optionally
    filtered by a case-insensitive substring ([q]) and/or an exact name
    list ([names]). *)
let list_predicates_detailed ?q ?names store =
  Db.Environment.load_or_build store >>= fun env ->
  let matches_filters (p : Query_environment.predicate_signature) =
    let matches_q =
      match q with
      | None -> true
      | Some needle ->
          let hay = String.lowercase_ascii p.name and needle = String.lowercase_ascii needle in
          let hl = String.length hay and nl = String.length needle in
          nl = 0 || (let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in go 0)
    in
    let matches_names = match names with None -> true | Some ns -> List.mem p.name ns in
    matches_q && matches_names
  in
  let predicates = List.filter matches_filters env.Query_environment.predicates in
  Lwt.return (Ok (Query_environment.to_json ~predicates env))

(** Query single predicate with validation *)
let query_predicate ~max_results store predicate =
  (* Validate predicate name *)
  match Query_validation.validate_predicate_name predicate with
  | Error err -> Lwt.return (Error (Query_validation.error_message err))
  | Ok () ->
      Model.query_predicate ~limit:max_results store predicate
      >>= fun facts ->
      let json = `Assoc [
        "predicate", `String predicate;
        "facts", `List (List.map (fun (fact : Fact.t) -> fact_to_json fact.arguments) facts);
        "count", `Int (List.length facts);
        "limited", `Bool true;
        "max_results", `Int max_results
      ] in
      Lwt.return (Ok json)

(** {2 Expressive query language and unified query dispatch}

    [run_query] is the single entry point for [POST /query] and the REPL's
    query commands. Queries are always the find/where language; BeingDB
    lowers them to its internal core form ({!Core_query}) and runs them
    through the one planner/executor, then applies the
    projection/order/distinct/limit/offset pipeline ({!Core_query.apply}).

    Every response is one of:
    - [Success json]: executed/validated/explained successfully. For all
      three actions (including [execute]), [json] always carries
      [languageVersion]/[environmentFingerprint], so an MCP client can
      cache schema/version knowledge purely from ordinary query
      responses, without a separate [/predicates] round trip.
    - [Invalid json]: a well-formed request whose *query* is invalid --
      [json] always has the shape [{"valid": false, "errors": [...],
      "warnings": [...], "language", "languageVersion",
      "environmentFingerprint"}]. This covers syntax errors, unknown
      predicates, arity/type mismatches, disconnected queries, unsafe
      negation, and unbound projections/ordering -- for every action.
    - [Failure {code; message}]: a transport or runtime failure that has
      nothing to do with the query's validity (malformed request,
      timeout, an internal error, or a bad [language]/[action]
      parameter). *)

type query_outcome =
  | Success of Yojson.Safe.t
  | Invalid of Yojson.Safe.t
  | Failure of { code : string; message : string }

(** A projected row (some cells [None] when an [optional] branch left a
    variable unbound), rendered as [{"Var": {...}, "Var2": null}]. *)
let row_to_json vars row =
  `Assoc (List.map2 (fun v value_opt -> (v, match value_opt with Some x -> Value.to_json x | None -> `Null)) vars row)

let core_error_json ~code ~message ?groups () =
  let extra = match groups with Some g -> [ ("groups", `List (List.map (fun grp -> `List (List.map (fun s -> `String s) grp)) g)) ] | None -> [] in
  `Assoc ([ ("code", `String code); ("message", `String message) ] @ extra)

(** [language]/[languageVersion]/[environmentFingerprint] fields, as
    appended to "execute" action success responses (in addition to
    validate/explain's {!validation_envelope}, which carries the same
    three fields) so clients can cache schema knowledge from ordinary
    query responses alone, without a separate [/predicates] call. *)
let with_environment_fields ~language (env : Query_environment.t) =
  [
    ("language", `String language);
    ("languageVersion", `String env.Query_environment.language_version);
    ("environmentFingerprint", `String env.Query_environment.fingerprint);
  ]

(** The single response envelope for [action: "validate"] and
    [action: "explain"]: [valid], the [errors]/
    [warnings] arrays (structured, per {!Validation_error.to_json}), and
    the dataset-identifying [language]/[languageVersion]/
    [environmentFingerprint] fields, plus whatever action-specific
    [extra] fields the caller supplies. *)
let validation_envelope ~language ~(env : Query_environment.t) ~valid errors_json warnings_json extra =
  `Assoc
    ([
       ("valid", `Bool valid);
       ("errors", `List errors_json);
       ("warnings", `List warnings_json);
       ("language", `String language);
       ("languageVersion", `String env.Query_environment.language_version);
       ("environmentFingerprint", `String env.Query_environment.fingerprint);
     ]
    @ extra)

let errors_warnings_json errors warnings =
  (List.map Validation_error.to_json errors, List.map Validation_error.warning_to_json warnings)

(** Parse and lower a DSL query string against a freshly built
    {!Query_environment}. Rebuilt per call: manifests are already
    persisted per-predicate, so this is a bounded, local reconstruction
    rather than a full-store scan (see {!Db.Environment.load_or_build}). *)
let lower_dsl store query_str =
  match Dsl_parser.parse query_str with
  | Error msg -> Lwt.return (`Parse_error msg)
  | Ok surface -> (
      Db.Environment.load_or_build store >>= fun env ->
      let { Dsl_lower.core_query; errors; warnings } = Dsl_lower.lower env surface in
      match (core_query, errors) with
      | _, _ :: _ -> Lwt.return (`Invalid (env, errors, warnings))
      | None, [] -> Lwt.return (`Internal_error "lowering produced neither a query nor errors")
      | Some cq, [] -> Lwt.return (`Valid (env, cq, warnings)))

let validate_dsl store query_str =
  lower_dsl store query_str >>= function
  | `Parse_error msg ->
      Db.Environment.load_or_build store >>= fun env ->
      Lwt.return (Invalid (validation_envelope ~language:"dsl" ~env ~valid:false [ core_error_json ~code:"syntax_error" ~message:msg () ] [] []))
  | `Internal_error message -> Lwt.return (Failure { code = "internal_error"; message })
  | `Invalid (env, errors, warnings) ->
      let errors_json, warnings_json = errors_warnings_json errors warnings in
      Lwt.return (Invalid (validation_envelope ~language:"dsl" ~env ~valid:false errors_json warnings_json []))
  | `Valid (env, cq, warnings) ->
      let _, warnings_json = errors_warnings_json [] warnings in
      Lwt.return
        (Success
           (validation_envelope ~language:"dsl" ~env ~valid:true [] warnings_json
              [
                ("variables", `List (List.map (fun v -> `String v) cq.Core_query.query.Query_ast.variables));
                ("projection", `List (List.map (fun v -> `String v) (Core_query.projected_variables cq)));
                ("distinct", `Bool cq.Core_query.distinct);
              ]))

let explain_dsl store query_str =
  lower_dsl store query_str >>= function
  | `Parse_error msg ->
      Db.Environment.load_or_build store >>= fun env ->
      Lwt.return (Invalid (validation_envelope ~language:"dsl" ~env ~valid:false [ core_error_json ~code:"syntax_error" ~message:msg () ] [] []))
  | `Internal_error message -> Lwt.return (Failure { code = "internal_error"; message })
  | `Invalid (env, errors, warnings) ->
      let errors_json, warnings_json = errors_warnings_json errors warnings in
      Lwt.return (Invalid (validation_envelope ~language:"dsl" ~env ~valid:false errors_json warnings_json []))
  | `Valid (env, cq, warnings) ->
      let _, warnings_json = errors_warnings_json [] warnings in
      Lwt.return
        (Success
           (validation_envelope ~language:"dsl" ~env ~valid:true [] warnings_json
              [
                ("projection", `List (List.map (fun v -> `String v) (Core_query.projected_variables cq)));
                ("distinct", `Bool cq.Core_query.distinct);
                ("normalizedCoreQuery", Explain_plan.normalized_core_query_json cq.Core_query.query);
                ("plan", `List (Explain_plan.build cq));
                ("planText", `String (Query_engine.explain cq.Core_query.query));
              ]))

(** Run [f] under the configured query timeout; a timeout or an
    unexpected exception becomes a structured [Failure]. *)
let with_query_timeout f =
  Lwt.catch
    (fun () -> Lwt_unix.with_timeout !Query_validation.Config.query_timeout f)
    (function
      | Lwt_unix.Timeout ->
          Lwt.return
            (Failure
               {
                 code = "timeout";
                 message =
                   Printf.sprintf
                     "Query timeout after %.0f seconds - query too expensive. Try limiting predicates or adding more specific constraints."
                     !Query_validation.Config.query_timeout;
               })
      | exn -> Lwt.return (Failure { code = "internal_error"; message = Printf.sprintf "Query error: %s" (Printexc.to_string exn) }))

(** Execute a lowered DSL query: the safety-checked, timed execution
    through {!Model.execute_query}, followed by {!Core_query.apply} for
    projection/distinct/order. The full projected result is always
    materialised, so [total] is exact; [offset]/[limit] and the server's
    [max_results] cap then select the page. Predicate names, arities,
    connectivity, and safe negation are all already guaranteed by
    {!Dsl_lower.lower} by the time a query reaches here. *)
let execute_dsl ~max_results store query_str =
  lower_dsl store query_str >>= function
  | `Parse_error msg ->
      Db.Environment.load_or_build store >>= fun env ->
      Lwt.return (Invalid (validation_envelope ~language:"dsl" ~env ~valid:false [ core_error_json ~code:"syntax_error" ~message:msg () ] [] []))
  | `Internal_error message -> Lwt.return (Failure { code = "internal_error"; message })
  | `Invalid (env, errors, warnings) ->
      let errors_json, warnings_json = errors_warnings_json errors warnings in
      Lwt.return (Invalid (validation_envelope ~language:"dsl" ~env ~valid:false errors_json warnings_json []))
  | `Valid (env, cq, warnings) ->
      let effective_limit = match cq.Core_query.limit with Some n -> min n max_results | None -> max_results in
      let offset = max 0 (Option.value cq.Core_query.offset ~default:0) in
      let run_body () =
        Model.execute_query store cq.Core_query.query >>= function
        | Error message ->
            Lwt.return (Failure { code = Query_validation.engine_error_code message; message })
        | Ok model_result ->
            let engine_result : Query_engine.result = { variables = model_result.Model.variables; bindings = model_result.Model.bindings } in
            let vars, all_rows = Core_query.apply { cq with Core_query.offset = None; limit = None } engine_result in
            let total = List.length all_rows in
            let rows = List.filteri (fun i _ -> i >= offset && i < offset + effective_limit) all_rows in
            let has_more = offset + List.length rows < total in
            (* Truncated: the server cap, not the query's own limit, cut the result. *)
            let truncated = has_more && (match cq.Core_query.limit with Some n -> n > max_results | None -> true) in
            let truncation_warning =
              if truncated then
                [
                  `Assoc
                    [
                      ("code", `String "results_truncated");
                      ( "message",
                        `String
                          (Printf.sprintf
                             "Only the first %d rows are returned (the server's max_results limit); more rows match. Page through \
                              them with 'offset', or add constraints to narrow the query."
                             max_results) );
                    ];
                ]
              else []
            in
            (* An empty first page is explained by the same data-aware
               diagnostics as the "diagnose" action. *)
            let first_page = offset = 0 in
            (* Nothing matched: no rows, or a count query whose counts are all 0. *)
            let nothing_matched = (rows = [] && not has_more) || (Core_query.is_count_query cq && model_result.Model.bindings = []) in
            (if nothing_matched && first_page then Db.Diagnostics.empty_result_fields store env query_str
             else Lwt.return [])
            >>= fun diagnosis ->
            Lwt.return
              (Success
                 (`Assoc
                   ([
                      ("variables", `List (List.map (fun v -> `String v) vars));
                      ("results", `List (List.map (row_to_json vars) rows));
                      ("count", `Int (List.length rows));
                      ("total", `Int total);
                      ("hasMore", `Bool has_more);
                      ("truncated", `Bool truncated);
                      ("warnings", `List (List.map Validation_error.warning_to_json warnings @ truncation_warning));
                    ]
                   @ diagnosis
                   @ with_environment_fields ~language:"dsl" env)))
      in
      with_query_timeout run_body

(** Run the DSL "diagnose" action: validation plus data-aware
    diagnostics and any repair BeingDB can prove
    ({!Query_diagnostics}), without executing, under the same query
    timeout as [execute]. An invalid query is reported in the body
    ([valid: false]), like the other diagnostics. *)
let diagnose_dsl store query_str =
  with_query_timeout (fun () ->
      Db.Environment.load_or_build store >>= fun env ->
      Db.Diagnostics.fields store env query_str >>= fun fields ->
      Lwt.return (Success (`Assoc (fields @ with_environment_fields ~language:"dsl" env))))

(** Unified query entry point for [POST /query] and the REPL. Queries are
    always the find/where language: [language] may be omitted or
    ["dsl"]; ["core"] is rejected as [unsupported_language] (BeingDB keeps
    the core form only internally, as the target the DSL lowers to).
    [action] is ["execute"] (default), ["validate"], ["explain"] or
    ["diagnose"]. An oversized query string is rejected before parsing. *)
let run_query ~max_results ?(language = "dsl") ?(action = "execute") store query_str =
  match (language, action) with
  | "core", _ ->
      Lwt.return
        (Failure
           {
             code = "unsupported_language";
             message =
               "The core query language is no longer accepted; send a find/where query instead (omit 'language' or set it to \"dsl\"), e.g. \"find A, W\\nwhere\\n  created(A, W)\".";
           })
  | "dsl", ("execute" | "validate" | "explain" | "diagnose") -> (
      match Query_validation.check_query_length query_str with
      | Error err -> Lwt.return (Failure { code = Query_validation.error_code err; message = Query_validation.error_message err })
      | Ok () -> (
          match action with
          | "execute" -> execute_dsl ~max_results store query_str
          | "validate" -> validate_dsl store query_str
          | "explain" -> explain_dsl store query_str
          | _ -> diagnose_dsl store query_str))
  | "dsl", _ ->
      Lwt.return
        (Failure
           { code = "unknown_action"; message = Printf.sprintf "Unknown action '%s' (expected 'execute', 'validate', 'explain' or 'diagnose')" action })
  | _, _ ->
      Lwt.return
        (Failure
           { code = "unknown_language"; message = Printf.sprintf "Unknown language '%s'; BeingDB queries use the find/where language (omit 'language' or set it to \"dsl\")" language })
