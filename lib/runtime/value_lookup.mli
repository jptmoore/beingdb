(** Value_lookup: finding the stored values a piece of text mentions
    ({!Make.resolve}), and everything the store holds about one value
    ({!Make.about}). Neither is part of the query language: they are
    lookups a client makes before or beside writing a query.

    {b Names.} A value is known by its own text (an atom's words, with
    underscores as spaces, or a string's contents) and by any names the
    data gives it with two optional, conventional predicates:

    - [label(Thing, Name)]: the display name of [Thing];
    - [alias(Thing, Name)]: another name or spelling of [Thing].

    [Name] is a string (optionally language-tagged) or an atom. Facts of
    these predicates are ordinary facts that queries can use; here they
    only name their first argument, so they are reported as [label] and
    [aliases] rather than as occurrences.

    {b Matching} ignores ASCII case and punctuation, and a possessive
    ['s]. Text is split into words, and word sequences (longest first) are
    matched against names:

    - exactly, by the value's own text, a label or an alias;
    - else ["fuzzy"]: the same number of words, each within a small edit
      distance (none for words under 5 bytes, 1 under 9, 2 under 16, else 3),
      among names whose first word starts with the same three letters;
    - else ["partial"]: a contiguous run of words of a longer name (e.g. a
      surname). A partial match needs a name cue -- a capitalised word that
      does not start a sentence, or a text that is only the name -- so
      ordinary words ("did", "the") do not match titles that contain them.
      It is reported only if it fits at most {!max_partial_candidates}
      values.

    Single-word matches need at least 3 characters and are never purely
    numeric. Matching is deterministic and uses no word lists; the name cue
    relies on ASCII capitals, so it suits scripts with letter case. *)

(** Longest text {!Make.resolve} accepts, in bytes. *)
val max_text_length : int

(** Longest name, in words, that is indexed for matching. *)
val max_name_words : int

(** A partial match whose words occur in more values than this is not
    reported. *)
val max_partial_candidates : int

(** Parse one literal in query syntax ([judith_goddard], ["Hey Bud"],
    [@1979], [42], ...) into a value. *)
val parse_value : string -> (Value.t, string) result

module Make (Store : Runtime_store.S) : sig
  (** The name index of a store: every atom, string and language-tagged
      string in its facts, with where it occurs, how many facts mention
      it, and its labels and aliases. Built by reading every fact once;
      build it once per store (or per environment fingerprint) and reuse
      it. *)
  type index

  val build_index : Store.t -> Query_environment.t -> index Lwt.t

  (** [resolve env index text]: the values [text] mentions. The JSON has
      [text] and [mentions], each with the matched [text], its byte
      offsets [start]/[end], the best [match] kind (["exact"], ["label"],
      ["alias"], ["fuzzy"] or ["partial"]), [candidateCount] and up to
      [max_candidates] (default 10) [candidates], most facts first. A
      candidate has [value] (typed), [literal] (in query syntax),
      [matchedName], [match], optional [label], [facts] and [occurs]
      (predicate, position and any declared role and semantic type).
      Several candidates mean the text is ambiguous. [Error (code,
      message)] if [text] is longer than {!max_text_length}. *)
  val resolve :
    ?max_candidates:int -> Query_environment.t -> index -> string -> (Yojson.Safe.t, string * string) result

  (** [about store env value]: every fact [value] occurs in, grouped by
      predicate and argument position. The JSON has [value], [literal],
      optional [label], [aliases], [facts] (the total) and [predicates],
      each group with [predicate], [position], optional [description],
      [roles] (declared roles, or [null]), [count], up to [limit] (default
      20) [facts] (argument lists, in a stable order) and [hasMore]. Uses
      indexed lookups only. *)
  val about : ?limit:int -> Store.t -> Query_environment.t -> Value.t -> Yojson.Safe.t Lwt.t
end
