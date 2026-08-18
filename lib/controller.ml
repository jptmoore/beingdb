(** Controller: Business logic layer for query execution and validation *)

open Lwt.Infix

(** Convert fact arguments to typed JSON: a list of [{"type":..,"value":..}]. *)
let fact_to_json (args : Value.t list) = `List (List.map Value.to_json args)

(** Convert a single typed binding to JSON: [{"Var": {"type":..,"value":..}, ...}]. *)
let binding_to_json (binding : Model.binding) =
  `Assoc (List.map (fun (var, value) -> (var, Value.to_json value)) binding)

(** Convert query result to JSON *)
let query_result_to_json ?offset ?limit result =
  let total_count = result.Model.total_count in
  
  (* Apply pagination *)
  let offset_val = Option.value offset ~default:0 in
  let limit_val = Option.value limit ~default:total_count in
  
  let paginated_bindings = 
    result.Model.bindings
    |> (fun l -> List.filteri (fun i _ -> i >= offset_val) l)
    |> (fun l -> List.filteri (fun i _ -> i < limit_val) l)
  in
  
  let bindings_json = List.map binding_to_json paginated_bindings in
  
  let response = [
    "variables", `List (List.map (fun v -> `String v) result.Model.variables);
    "results", `List bindings_json;
    "count", `Int (List.length paginated_bindings);
    "total", `Int total_count;
  ] in
  
  let response = match offset with
    | Some o -> response @ ["offset", `Int o]
    | None -> response
  in
  let response = match limit with
    | Some l -> response @ ["limit", `Int l]
    | None -> response
  in
  
  `Assoc response

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
  Query_environment.load_or_build store >>= fun env ->
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
  let predicate_json (p : Query_environment.predicate_signature) =
    `Assoc
      [
        ("name", `String p.name);
        ("arity", `Int p.arity);
        ("count", `Int p.count);
        ( "arguments",
          `List
            (List.map
               (fun (a : Query_environment.argument_signature) ->
                 `Assoc [ ("position", `Int a.position); ("types", `List (List.map (fun t -> `String t) a.types)) ])
               p.arguments) );
        ("examples", `List (List.map (fun args -> `List (List.map Value.to_json args)) p.examples));
      ]
  in
  Lwt.return
    (Ok
       (`Assoc
         [
           ("predicates", `List (List.map predicate_json predicates));
           ("environmentFingerprint", `String env.Query_environment.fingerprint);
           ("languageVersion", `String env.Query_environment.language_version);
         ]))

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

(** Execute query with timeout and validation *)
let execute_query ~max_results store query_str ~offset ~limit =
  (* Reject oversized payloads before even tokenizing/parsing *)
  match Query_validation.check_query_length query_str with
  | Error err -> Lwt.return (Error (Query_validation.error_message err))
  | Ok () -> (
  (* Parse query *)
  match Query_parser.parse_query_result query_str with
  | Error msg -> Lwt.return (Error msg)
  | Ok query ->
      (* Validate query structure and parameters *)
      match Query_validation.validate_query query offset limit with
      | Error err -> Lwt.return (Error (Query_validation.error_message err))
      | Ok (valid_offset, valid_limit) ->
          (* Enforce max results limit *)
          let limit_to_use = 
            match valid_limit with
            | Some user_limit -> Some (min user_limit max_results)
            | None -> Some max_results
          in
          
          (* Determine execution strategy *)
          let pattern_count =
            List.length
              (List.filter (function Query_ast.Pattern _ -> true | _ -> false) query.Query_ast.clauses)
          in
          let is_join = pattern_count > 1 in
          let use_streaming = is_join && Option.is_some limit_to_use in
          
          (* Execute with timeout *)
          Lwt.catch
            (fun () ->
              Lwt_unix.with_timeout !Query_validation.Config.query_timeout (fun () ->
                if use_streaming then
                  let offset_val = Option.value valid_offset ~default:0 in
                  let limit_val = Option.get limit_to_use in
                  
                  Model.execute_query_streaming store query ~offset:offset_val ~limit:limit_val
                  >>= (function
                  | Error msg -> Lwt.return (Error msg)
                  | Ok result ->
                      let result_json = `Assoc [
                        "variables", `List (List.map (fun v -> `String v) result.Model.variables);
                        "results", `List (List.map binding_to_json result.Model.bindings);
                        "count", `Int (List.length result.Model.bindings);
                      ] in
                      Lwt.return (Ok result_json))
                else
                  Model.execute_query store query
                  >>= (function
                  | Error msg -> Lwt.return (Error msg)
                  | Ok result -> Lwt.return (Ok (query_result_to_json ?offset:valid_offset ?limit:limit_to_use result)))
              )
            )
            (function
              | Lwt_unix.Timeout ->
                  let msg = Printf.sprintf "Query timeout after %.0f seconds - query too expensive. Try limiting predicates or adding more specific constraints." 
                    !Query_validation.Config.query_timeout in
                  Lwt.return (Error msg)
              | exn ->
                  Lwt.return (Error (Printf.sprintf "Query error: %s" (Printexc.to_string exn)))
            ))

(** {2 Expressive query language and unified query dispatch}

    [run_query] is the single entry point for [POST /query] and the REPL's
    query commands, covering both the core and expressive (DSL) query
    languages and all three actions (execute/validate/explain). It shares
    the exact same planner/executor as {!execute_query} above -- the DSL
    path only adds parsing, environment-aware validation, and the
    projection/order/distinct/limit/offset post-processing pipeline
    ({!Core_query.apply}).

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
      negation, and unbound projections/ordering -- for both languages
      and all three actions.
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

let validation_error_error_json (err : Query_validation.validation_error) =
  let groups = match err with Query_validation.DisconnectedQuery groups -> Some groups | _ -> None in
  core_error_json ~code:(Query_validation.error_code err) ~message:(Query_validation.error_message err) ?groups ()

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
    [action: "explain"], in both languages: [valid], the [errors]/
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

(** Run the core-language "validate" action: parse + structural
    validation only, no execution. *)
let validate_core store query_str =
  Query_environment.load_or_build store >>= fun env ->
  match Query_parser.parse_query_result query_str with
  | Error msg -> Lwt.return (Invalid (validation_envelope ~language:"core" ~env ~valid:false [ core_error_json ~code:"syntax_error" ~message:msg () ] [] []))
  | Ok query -> (
      match Query_validation.validate_query query None None with
      | Error err -> Lwt.return (Invalid (validation_envelope ~language:"core" ~env ~valid:false [ validation_error_error_json err ] [] []))
      | Ok _ ->
          Lwt.return
            (Success
               (validation_envelope ~language:"core" ~env ~valid:true [] []
                  [ ("variables", `List (List.map (fun v -> `String v) query.Query_ast.variables)) ])))

(** Run the core-language "explain" action: parse then produce the
    structured plan and human-readable [planText], without executing. *)
let explain_core store query_str =
  Query_environment.load_or_build store >>= fun env ->
  match Query_parser.parse_query_result query_str with
  | Error msg -> Lwt.return (Invalid (validation_envelope ~language:"core" ~env ~valid:false [ core_error_json ~code:"syntax_error" ~message:msg () ] [] []))
  | Ok query ->
      let cq = Core_query.of_query query in
      Lwt.return
        (Success
           (validation_envelope ~language:"core" ~env ~valid:true [] []
              [
                ("projection", `List (List.map (fun v -> `String v) (Core_query.projected_variables cq)));
                ("distinct", `Bool cq.Core_query.distinct);
                ("normalizedCoreQuery", Explain_plan.normalized_core_query_json query);
                ("plan", `List (Explain_plan.build cq));
                ("planText", `String (Query_engine.explain query));
              ]))

(** The unified, structured counterpart to {!execute_query} for
    [language: "core"], reusing its exact execution behaviour (same
    parse, validate, timeout, and streaming strategy) but classifying
    parse/validation failures as [Invalid] (query-invalid) rather than a
    bare runtime [Failure]. *)
let execute_core_structured ~max_results store query_str ~offset ~limit =
  Query_environment.load_or_build store >>= fun env ->
  match Query_parser.parse_query_result query_str with
  | Error msg -> Lwt.return (Invalid (validation_envelope ~language:"core" ~env ~valid:false [ core_error_json ~code:"syntax_error" ~message:msg () ] [] []))
  | Ok query -> (
      match Query_validation.validate_query query offset limit with
      | Error err -> Lwt.return (Invalid (validation_envelope ~language:"core" ~env ~valid:false [ validation_error_error_json err ] [] []))
      | Ok _ -> (
          execute_query ~max_results store query_str ~offset ~limit >>= function
          | Ok (`Assoc fields) -> Lwt.return (Success (`Assoc (fields @ with_environment_fields ~language:"core" env)))
          | Ok json -> Lwt.return (Success json)
          | Error message -> Lwt.return (Failure { code = "execution_error"; message })))

let errors_warnings_json errors warnings =
  (List.map Validation_error.to_json errors, List.map Validation_error.warning_to_json warnings)

(** Parse and lower a DSL query string against a freshly built
    {!Query_environment}. Rebuilt per call: manifests are already
    persisted per-predicate, so this is a bounded, local reconstruction
    rather than a full-store scan (see {!Query_environment.load_or_build}). *)
let lower_dsl store query_str =
  match Dsl_parser.parse query_str with
  | Error msg -> Lwt.return (`Parse_error msg)
  | Ok surface -> (
      Query_environment.load_or_build store >>= fun env ->
      let { Dsl_lower.core_query; errors; warnings } = Dsl_lower.lower env surface in
      match (core_query, errors) with
      | _, _ :: _ -> Lwt.return (`Invalid (env, errors, warnings))
      | None, [] -> Lwt.return (`Internal_error "lowering produced neither a query nor errors")
      | Some cq, [] -> Lwt.return (`Valid (env, cq, warnings)))

let validate_dsl store query_str =
  lower_dsl store query_str >>= function
  | `Parse_error msg ->
      Query_environment.load_or_build store >>= fun env ->
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
      Query_environment.load_or_build store >>= fun env ->
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

(** Execute a lowered DSL query: the same safety-checked, timed,
    optionally-streamed execution strategy as {!execute_query}, followed
    by {!Core_query.apply} for projection/distinct/order/limit/offset.
    Predicate names, arities, connectivity, and safe negation are all
    already guaranteed by {!Dsl_lower.lower} by the time a query reaches
    here, so (unlike the core-language path) there is no separate
    post-lowering safety-validation step to re-run. *)
let execute_dsl ~max_results store query_str =
  lower_dsl store query_str >>= function
  | `Parse_error msg ->
      Query_environment.load_or_build store >>= fun env ->
      Lwt.return (Invalid (validation_envelope ~language:"dsl" ~env ~valid:false [ core_error_json ~code:"syntax_error" ~message:msg () ] [] []))
  | `Internal_error message -> Lwt.return (Failure { code = "internal_error"; message })
  | `Invalid (env, errors, warnings) ->
      let errors_json, warnings_json = errors_warnings_json errors warnings in
      Lwt.return (Invalid (validation_envelope ~language:"dsl" ~env ~valid:false errors_json warnings_json []))
  | `Valid (env, cq, warnings) ->
      let effective_limit = match cq.Core_query.limit with Some n -> min n max_results | None -> max_results in
      let pattern_count = List.length (List.filter (function Query_ast.Pattern _ -> true | _ -> false) cq.Core_query.query.Query_ast.clauses) in
      let is_join = pattern_count > 1 in
      let use_streaming = is_join && cq.Core_query.projection = None && (not cq.Core_query.distinct) && cq.Core_query.order_by = [] in
      let run_body () =
        let run_model () =
          if use_streaming then
            Model.execute_query_streaming store cq.Core_query.query ~offset:(Option.value cq.Core_query.offset ~default:0) ~limit:effective_limit
          else Model.execute_query store cq.Core_query.query
        in
        run_model () >>= function
        | Error message -> Lwt.return (Failure { code = "execution_error"; message })
        | Ok model_result ->
            let vars, rows =
              if use_streaming then (model_result.Model.variables, List.map (List.map (fun (_, v) -> Some v)) model_result.Model.bindings)
              else
                let engine_result : Query_engine.result = { variables = model_result.Model.variables; bindings = model_result.Model.bindings } in
                let cq_bounded = { cq with Core_query.limit = Some effective_limit } in
                Core_query.apply cq_bounded engine_result
            in
            Lwt.return
              (Success
                 (`Assoc
                   ([
                      ("variables", `List (List.map (fun v -> `String v) vars));
                      ("results", `List (List.map (row_to_json vars) rows));
                      ("count", `Int (List.length rows));
                      ("warnings", `List (List.map Validation_error.warning_to_json warnings));
                    ]
                   @ with_environment_fields ~language:"dsl" env)))
      in
      Lwt.catch
        (fun () -> Lwt_unix.with_timeout !Query_validation.Config.query_timeout run_body)
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

(** Unified query entry point: dispatches on [language] ("core" | "dsl",
    default "core") and [action] ("execute" | "validate" | "explain",
    default "execute"). Rejects an oversized raw query string up front,
    before either language's parser runs, so this one guard covers both
    languages and all three actions. *)
let run_query ~max_results ?(language = "core") ?(action = "execute") store query_str ~offset ~limit =
  match Query_validation.check_query_length query_str with
  | Error err -> Lwt.return (Failure { code = Query_validation.error_code err; message = Query_validation.error_message err })
  | Ok () -> (
  match (language, action) with
  | "core", "execute" -> execute_core_structured ~max_results store query_str ~offset ~limit
  | "core", "validate" -> validate_core store query_str
  | "core", "explain" -> explain_core store query_str
  | "dsl", "execute" -> execute_dsl ~max_results store query_str
  | "dsl", "validate" -> validate_dsl store query_str
  | "dsl", "explain" -> explain_dsl store query_str
  | _, ("execute" | "validate" | "explain") ->
      Lwt.return (Failure { code = "unknown_language"; message = Printf.sprintf "Unknown language '%s' (expected 'core' or 'dsl')" language })
  | _, _ ->
      Lwt.return (Failure { code = "unknown_action"; message = Printf.sprintf "Unknown action '%s' (expected 'execute', 'validate', or 'explain')" action }))

