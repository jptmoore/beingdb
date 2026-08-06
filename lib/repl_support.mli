(** Repl_support: reusable, testable logic for the interactive REPL
    (`beingdb repl`), kept out of bin/main.ml so it can be unit tested
    without a terminal. The REPL itself remains a thin CLI loop; this
    module only touches the store for the one operation the HTTP API
    intentionally does not expose: loading a fact file directly into an
    already-compiled Pack store. Ordinary queries are executed through
    {!Controller.execute_query}, exactly as the HTTP API does. *)

(** Whether a `:load` target should be treated as a predicate source file
    (facts, written into the store) or a batch of queries (executed and
    reported, never written anywhere). *)
type load_kind = Facts | Queries

(** Decide {!load_kind} from a file's extension: [.pl], [.pro] and
    [.facts] are treated as facts; anything else (including no
    extension) defaults to queries. Use the REPL's explicit
    [:loadfacts]/[:loadqueries] commands to override this. *)
val load_kind_of_filename : string -> load_kind

(** Parse every fact in [path] (predicate source syntax, one fact per
    line, same as a compiled predicate file), group by predicate name,
    and batch-write each group into [store] -- the moral equivalent of
    `beingdb compile` for a single ad-hoc file. Returns one human-readable
    summary line per predicate group (e.g. ["created (3 facts)"] or
    ["created: arity mismatch"]), plus any per-line parse errors appended
    at the end. [Error msg] only for whole-file failures (e.g. the file
    cannot be read, or it contains no recognizable facts at all). *)
val load_facts_file : Pack_backend.t -> string -> (string list, string) result Lwt.t

(** Run every non-blank, non-comment line of [path] as a query (via
    {!Controller.execute_query}), returning [(query_text, result)] pairs
    in file order. Never writes to the store. *)
val run_queries_file :
  max_results:int ->
  Pack_backend.t ->
  string ->
  (string * (Yojson.Safe.t, string) result) list Lwt.t
