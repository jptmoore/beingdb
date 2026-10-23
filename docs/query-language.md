# BeingDB Query Language

BeingDB is queried with a line-oriented `find`/`where` language. A
query names the variables to return, then lists predicate patterns and
comparisons, one per line:

```
find Artist, Work
where
  created(Artist, Work)
  shown_in(Work, Exhibition)
```

The same language is used by `POST /query`, the REPL and query files.
On top of patterns, joins and typed comparisons it has `optional`,
`either`/`or`, `not`, `order by`, `limit`, `offset` and `distinct`, and
every query is validated against the compiled data before it runs
(unknown predicates, arity, literal types), with structured error
messages.

## Facts syntax

Facts are predicates applied to typed literal arguments:

```prolog
person(alice_smith).
label(alice_smith, "Alice Smith").
label(alice_smith, "Alice Smith"@en).

birth_number(alice_smith, 1972).
confidence(assertion_1, 0.92).
reviewed(assertion_1, true).

birth_year(alice_smith, @1972).
published(issue_1, @1972-05).
opened(exhibition_1, @1972-05-14).

captured_at(
  capture_1,
  @2026-08-06T12:15:00Z
).

homepage(
  organisation_1,
  <https://example.org/>
).
```

**Rules:**
- Predicate names: lowercase, alphanumeric + underscore only.
- Consistent arity: all facts for a predicate must have the same number
  of arguments.
- One fact per line, terminated with `.`.
- Type is determined directly from literal syntax; no schema is
  required. Optional declarations (below) document predicates but never
  change typing.

### Predicate declarations (optional)

Facts work on their own: BeingDB always works out each predicate's
arity, value types, fact count and examples. You can optionally add a
**declaration** to say what a predicate means. A declaration is a
comment line starting with `%!` placed in the predicate's file, usually
just above the facts. Each part is optional; add only what helps.

**Simple description.** Name the predicate on a `%!` line and describe
it on the `%` lines that follow:

```prolog
%! created_by
% Relates a work to the artist or creator who made it.
created_by("Work A", "Artist A").
```

**Argument roles.** Name each argument, in order, to make clear which
argument is which:

```prolog
%! created_by(Work, Artist)
created_by("Work A", "Artist A").
```

**Roles plus description** (recommended):

```prolog
%! created_by(Work, Artist)
% Relates a work to the artist or creator who made it.
created_by("Work A", "Artist A").
```

**Advanced: semantic types.** A role may be refined with `:` and a
semantic type, on any or all arguments:

```prolog
%! created_by(Work:work, Artist:person)
% Relates a work to the artist or creator who made it.
created_by("Work A", "Artist A").
```

Here `Work` and `Artist` are **argument roles**, and `work` and `person`
are optional **semantic types**. Semantic types are never required.

Rules:

- A role is a capitalised name (`[A-Z][A-Za-z0-9_]*`), like a query
  variable. Roles in one declaration must be distinct, and there must
  be one per argument.
- A semantic type is a lowercase label (`[a-z][a-z0-9_]*`). BeingDB
  records it but does not check it against the facts. It is separate
  from the value types BeingDB observes (`atom`, `string`, `year`, ...).
- The description is the `%` lines directly after the `%!` line, up to
  the first line that does not start with `%` (a blank line or a fact).
  Lines are joined with spaces; an empty `%` line starts a new
  paragraph. A bare `%! name` must have a description.
- Only `%!` starts a declaration. Ordinary `%` comments (headers,
  provenance notes, ...) are never treated as metadata.
- Declarations are documentation only: they do not change query
  results, validation or how values are typed.
- Declarations are comments, so files containing them still compile
  with older BeingDB versions.

`beingdb compile` (and the REPL's `:load`) stores the declaration with
the predicate. A declaration that cannot be parsed, names a different
predicate, repeats an earlier one, or declares a different number of
arguments from the facts is reported as a warning and ignored. It never
fails the compile. Declarations are returned by
[predicate introspection](#predicate-introspection-get-predicatesdetailedtrue).

### Literal types

| Type          | Syntax                                   | Example                            |
|---------------|-------------------------------------------|-------------------------------------|
| Atom          | bare lowercase identifier                 | `alice_smith`                       |
| String        | double-quoted                             | `"Alice Smith"`                     |
| Language-tagged string | double-quoted + `@tag` (BCP-47-ish) | `"Alice Smith"@en`                  |
| Signed integer | optional `-`, digits                      | `1972`, `-42`                       |
| Exact decimal | digits `.` digits                          | `0.92`, `-3.50`                     |
| Boolean       | `true` / `false` (reserved words)          | `true`                              |
| Year          | `@YYYY`                                   | `@1972`                             |
| Year-month    | `@YYYY-MM`                                | `@1972-05`                          |
| Calendar date | `@YYYY-MM-DD`                             | `@1972-05-14`                       |
| UTC instant   | `@YYYY-MM-DDTHH:MM:SS[.fff](Z\|±HH:MM)`     | `@2026-08-06T12:15:00Z`             |
| URI           | `<...>`                                   | `<https://example.org/>`            |

The following remain distinct values, of four different types:

```prolog
1979          integer
@1979         year
"1979"        string
year_1979     atom
```

`@1979` (year) and `@1979-01-01` (date) are also distinct and never
converted into one another.

Decimals are canonicalized: `0.9`, `0.90` and `0.900` are the same value
and encode identically -- BeingDB never stores decimals as `float`, so
this canonicalization is exact.

Instants are normalized to UTC on parsing: `@2026-08-06T12:15:00+01:00`
and `@2026-08-06T11:15:00Z` refer to the same instant and are stored
identically.

Not yet supported: null literals, list literals, uncertain dates, date
intervals.

## Query syntax

```
find [distinct] Var, Var, ...
where
  <clause>
  <clause>
  optional
    <clause>*
  either
    <clause>*
  or
    <clause>*
  not
    <clause>*
order by Var [ascending|descending], ...
limit N
offset N
```

- `find` lists the variables to return, in order. `find distinct`
  removes duplicate rows from the result.
- `where` starts the clause list. Each line holds one clause: a
  [predicate pattern](#query-patterns), a
  [comparison](#comparisons), or a `between ... and ...` range.
- `optional` is a left join: clauses inside it may fail to match without
  discarding the row. Variables they would bind come back unbound
  (`null` in JSON).
- `either` / `or` is disjunction: at least one branch must match; each
  branch's bindings contribute rows (a union, not a join, across
  branches).
- `not` is negation-as-failure: the row is kept only if the nested
  clauses produce *no* matches. Every variable used inside `not` must
  also be bound by a positive clause elsewhere in the query; a variable
  that only appears inside a negation is rejected as `unsafe_negation`.
- `order by`, `limit`, and `offset` apply to the final, projected result
  (after `optional`/`either`/`not` have been resolved), not to any one
  clause. `ascending` (the default) and `descending` may be shortened
  to `asc`/`desc`. `limit` must be at least 1; `offset` at least 0. See
  [Pagination](#pagination).

Layout rules:

- One clause per line. A predicate pattern cannot be split across
  lines.
- Blank lines and lines starting with `%` or `#` are ignored (but in the
  REPL and in query files a blank line ends the query).
- Indentation is for readability only. An `optional`, `either`, `or` or
  `not` block runs until the next `optional`/`either`/`or`/`not` line or
  the `order by`/`limit`/`offset` tail, so put plain clauses before the
  first block. Blocks cannot be nested.
- Whitespace inside a line is insignificant except inside quoted
  strings, so a comma in a string literal is never mistaken for an
  argument separator:

  ```
  find Work
  where
    title(Work, "Smith, Jones and Brown")
  ```

- Year literals need the `@` prefix (`@1972`). A bare `1972` is an
  integer, not a year.

Over HTTP the query is a JSON string, so line breaks are written `\n`:

```bash
curl -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Artist, Work\nwhere\n  created(Artist, Work)\n  shown_in(Work, Exhibition)"}'
```

Malformed input (a missing `where`, unmatched parentheses, an
incomplete comparison, a bad `limit` value, ...) is rejected with a
`syntax_error` that names the line, rather than being silently
misinterpreted.

## Query terms

| Type | Syntax | Example | Description |
|------|--------|---------|-------------|
| **Variable** | Uppercase | `Work`, `Year` | Binds to a typed value during matching |
| **Wildcard** | `_` | `_` | Matches anything, not bound |
| **Literal** | any typed literal from the table above | `tina_keane`, `"text"`, `1979`, `@1979`, `<https://x>` | Exact-match constant of that type |

## Query patterns

A pattern line names a predicate and gives one term per argument. A
fact matches when every literal argument is equal to the fact's value
at that position; variables bind to the fact's values.

### Single pattern

```
find Artist, Work
where
  created(Artist, Work)
```

### Multiple patterns (joins)

Patterns on separate `where` lines join on shared variables:

```
find Artist, Work, Exhibition
where
  created(Artist, Work)
  shown_in(Work, Exhibition)
```

Joins can chain across more than two patterns, following a variable
through several relationships:

```
find Artist, Venue
where
  created(Artist, Work)
  shown_in(Work, Exhibition)
  held_at(Exhibition, Venue)
```

This follows the factual chain `Artist -> Work -> Exhibition -> Venue`
without requiring those relationships to be reconstructed from
unstructured text. Variables used only to join (`Work`, `Exhibition`
here) need not appear in `find`.

### Typed literals in patterns

```
find Work
where
  created_in_year(Work, @1979)
```

Other examples of pattern lines with typed literals:

```
captured_at(Capture, @2026-08-06T12:15:00Z)
homepage(Organisation, <https://example.org/>)
label(Person, "Alice Smith")
```

### Wildcards and constants

```
find Artist
where
  created(Artist, _)
```

```
find Work
where
  created(tina_keane, Work)
```

## Comparisons

A `where` line may also be a typed comparison. The parser builds a
structured AST for these (`Query_ast.Compare` / `Query_ast.Between`);
they are never interpreted from text at execution time.

```
=   !=   <   <=   >   >=   between ... and ...
```

Examples:

```
find Person, Year
where
  birth_year(Person, Year)
  Year >= 1900
  Year < 1950
```

```
find Assertion, Score
where
  confidence(Assertion, Score)
  Score >= 0.8
```

```
find Capture
where
  captured_at(Capture, Date)
  Date between @2019-01-01 and @2019-12-31
```

`between LOWER and UPPER` is inclusive at both ends.

### Equality is type-aware

```
1979        integer
@1979       year
"1979"      string
year_1979   atom
```

are never equal to each other, even though comparing any of them with
`=` is syntactically valid (it simply always evaluates to false across
types).

### Ordering is restricted to compatible types

Valid:

```
integer < integer
decimal < decimal
integer < decimal        (integer promoted to decimal)
integer < year           (a narrow, explicit promotion -- see below)
year < year
year_month < year_month
date < date
instant < instant
```

`=` / `!=` (but not `<`, `<=`, `>`, `>=`) are additionally valid between
two values of the same non-ordered type: `string = string`, `URI = URI`,
`boolean = boolean`, `atom = atom`.

**Numeric promotion**: an `integer` compared against a `decimal` is
promoted to a decimal at scale 0 before comparing, so `5 < 5.5` and
`5.0 = 5` both hold. An `integer` compared against a `year` is likewise
promoted (so `Year >= 1900` works on a `birth_year` year value); this
promotion is intentionally narrow and does **not** extend to `date` or
`year_month` -- a year is never silently treated as a date.

Temporal comparisons across genuinely different temporal types are
rejected:

```
@1979 < @1979-04-01      rejected: year vs date
```

Whenever a variable's type can be inferred from the patterns that bind
it, a comparison that can never succeed is rejected **before** the query
runs, with a structured `comparison_type_mismatch` error (see
[Validation](#validation)). A comparison that cannot be checked
statically (for example between two variables) is checked as rows are
evaluated, and an invalid one returns a descriptive error instead of
silently filtering results, for example:

```
Cannot compare a date with an integer.

Left value: @1979-04-01
Right value: 1979

Did you mean @1979 (year only) or @1979-04-01 (full date)?
```

## Optional, either/or and not

### Unbound optional variables: one stable JSON shape

Every variable in `find` appears as a key in every result row, whether
or not an `optional` block actually matched -- an unmatched variable is
`null`, it is never simply omitted from the row:

```json
{ "Person": { "type": "atom", "value": "alice" }, "Label": null }
```

This is the same shape everywhere a result row is produced: `execute`
responses and the REPL's printed JSON. `distinct` treats two `null`s in
the same position as equal (so rows differing only by an unmatched
optional variable are still deduplicated together). `order by` on a
variable that's `null` in some rows uses a fixed policy -- **nulls
last**, for both `ascending` and `descending` -- so ordering is
deterministic regardless of how many rows have an unmatched optional
value.

### Example

```
find Artist, Work, Nationality
where
  artist(Artist)
  created(Artist, Work)
  optional
    nationality(Artist, Nationality)
  not
    withdrawn(Work)
order by Artist ascending
limit 20
```

### More examples

Disjunction with `either`/`or` -- a row is kept if any branch matches:

```
find Work
where
  either
    uses_medium(Work, video)
  or
    uses_medium(Work, video_installation)
```

`distinct` to deduplicate the projected rows:

```
find distinct Medium
where
  uses_medium(_, Medium)
```

A comparison alongside a join, ordered and paginated:

```
find Work, Year
where
  created_in_year(Work, Year)
  Year >= 1980
order by Year descending
limit 10
offset 0
```

## Query planning

BeingDB does not fall back to "scan everything, then filter" whenever a
positional index can answer a comparison directly. For:

```
find Capture, Date
where
  captured_at(Capture, Date)
  Date >= @2019-01-01
  Date < @2020-01-01
```

the planner:

1. associates both comparisons with the `Date` variable;
2. identifies that `Date` is argument 1 of `captured_at/2`;
3. selects the instant/date range index for that argument position;
4. scans only that position's index (not the whole predicate, and not
   every other predicate);
5. binds `Capture` and `Date` from the matching facts, then
   double-checks every comparison exactly against the decoded fact.

Joins are also resolved via the positional index: once a shared variable
is bound by an earlier pattern, the next pattern that uses it performs
an equality-index lookup with that concrete value, rather than a nested
scan of every fact.

When no pattern argument is a literal or a comparison-constrained
variable, execution falls back to a full predicate scan (still
per-predicate, not across the whole store). See
[internals.md](internals.md#33-range-lookup-and-its-documented-limitation)
for the current limitation of range scans (correct, but not yet a true
sorted binary search).

The order of `where` lines does not matter: the planner picks the most
constrained pattern first. Use the `explain` action (see
[HTTP](#http-post-query)) to see the plan without running the query.

## Pagination

Paging is part of the query text: put `limit N` and `offset N` at the
end of the query.

```
find Artist, Work
where
  created(Artist, Work)
order by Work
limit 10
offset 20
```

```bash
curl -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Artist, Work\nwhere\n  created(Artist, Work)\norder by Work\nlimit 10\noffset 20"}'
```

Request-level `"offset"` and `"limit"` JSON fields are not accepted
(`unsupported_parameter`, HTTP 400).

Every `execute` response carries:

- `count` -- rows in this response;
- `total` -- rows the whole query matches (after `distinct`),
  independent of `limit`, `offset` and the server's `max_results` cap;
- `hasMore` -- `true` when more matching rows exist after this page;
- `truncated` -- `true` when the server's `max_results` cap, rather than
  the query's own `limit`, cut the result. A `results_truncated`
  warning is added then, so a client never mistakes a capped result for
  the complete answer.

```json
{
  "variables": ["Artist", "Work"],
  "results": [...],
  "count": 10,
  "total": 156,
  "hasMore": true,
  "truncated": false,
  "warnings": [],
  ...
}
```

Without a `limit`, a query returns up to `max_results` rows (1000 by
default). Add `order by` when paging so pages are stable. BeingDB
computes the whole projected result to report `total` and then returns
the requested page, so paging through a large result does not make each
page cheaper to compute; add constraints to narrow the query instead.

## Query protections

Built-in safety limits prevent runaway or malicious queries, all
configurable per-server without recompiling (see
[Safety limits](api.md#safety-limits) for the config file and defaults):

- **Timeout:** 5 seconds maximum execution time by default, for
  `execute` and `diagnose` alike.
- **Matching rows:** a query may match at most 10,000 rows by default
  (`max_intermediate_results`); one that matches more fails with
  `result_too_large` instead of returning a partial result.
- **Diagnostics budget:** data-aware checks that read a whole predicate
  skip predicates with more than 50,000 facts (`max_diagnostic_facts`)
  and say so with an info-level `check_skipped` diagnostic.
- **Result limit:** 1000 by default, via `--max-results` or the config
  file's `max_results`.
- **Query length:** 20,000 bytes by default; longer raw query strings
  are rejected (`query_too_long`, HTTP 413) before parsing.
- **Concurrency:** 20 simultaneously in-flight requests by default
  (queries and the `GET /predicates`/`GET /query/:predicate` reads);
  further requests get `server_busy` (HTTP 429) until one finishes.
- **Connectivity:** a query's predicate patterns must form a single
  connected component -- every pattern must be reachable from every
  other one through a shared variable, a shared constant, or a
  comparison that references both.

  Repeated predicates are always fine, including self-joins and
  multi-hop chains:

  ```
  find Person, Grandparent
  where
    parent(Person, Parent)
    parent(Parent, Grandparent)
  ```

  What's rejected is a genuinely **disconnected** query -- one that
  would compute an unconstrained Cartesian product because two pattern
  groups share nothing:

  ```
  find Person, Organisation
  where
    person(Person)
    organisation(Organisation)
  ```

  Joining them through a shared variable is fine:

  ```
  find Person, Organisation
  where
    person(Person)
    works_for(Person, Organisation)
    organisation(Organisation)
  ```

  An `optional`/`either`-`or`/`not` block counts as connected if it
  shares a variable with the rest of the query; each `either`/`or`
  branch is additionally checked for its own internal connectivity. A
  disconnected query is rejected with a `disconnected_query` error (see
  [Validation](#validation)).

## What the query language does NOT support

- **Aggregation:** no `COUNT`, `SUM`, `GROUP BY`. (`total` in the
  response counts matching rows, but there is no in-query aggregation.)
- **Arithmetic:** no `Y = X + 1`.
- **Recursion:** no transitive closure or path queries.
- **Functions:** no computed values or transformations.
- **Nested blocks:** `optional`, `either`/`or` and `not` blocks cannot
  contain further blocks.
- **Uncertain dates or date intervals.**
- **A user-authored type schema** -- value types are always inferred,
  never declared. (Optional [predicate declarations](#predicate-declarations-optional)
  document roles and meaning but do not affect typing.)

## Validation

Every query is validated against a **query environment** built from the
compiled store's inferred per-predicate schema (arity, per-argument
observed types, fact counts, and a few bounded examples) -- no
user-authored schema is required, and optional predicate declarations
play no part in validation. Validation reports *every* problem found,
not just the first, as a list of structured errors, each with a stable
`code` and a human-readable `message`, plus `line`/`column` where
applicable:

| Error code | Meaning |
|---|---|
| `syntax_error` | Malformed `find`/`where`/clause/`order by`/`limit`/`offset` syntax. |
| `unknown_predicate` | Predicate not found in the store; includes ranked name suggestions (edit distance + token overlap, no embeddings). |
| `arity_mismatch` | Predicate used with the wrong number of arguments. |
| `literal_type_mismatch` | A literal's type never occurs at that argument position in the compiled data. |
| `comparison_type_mismatch` | A `<`/`<=`/`>`/`>=`/`between` comparison can never succeed for the inferred types on both sides (e.g. `date` vs `integer`); includes `leftType`, `rightType`, and a `suggestion` when one applies. |
| `disconnected_query` | The query's patterns split into more than one connected component (see [Query protections](#query-protections)); includes `groups`, one entry per disconnected component. |
| `unbound_projection` | A `find` variable never appears in `where`. |
| `unbound_order_variable` | An `order by` variable never appears in `where`. |
| `unsafe_negation` | A `not` block uses a variable not bound by any positive clause elsewhere in the query. |

A query whose argument position has *more than one* observed type (a
heterogeneous column) but whose literal matches one of them is not an
error -- it produces a `heterogeneous_position` **warning** instead,
since the query is well-formed but only targets part of that column.

The `diagnose` action goes further and checks the query against the
data itself (constants that occur nowhere, joins that can never match,
comparisons no value satisfies, ...); see
[API: Diagnose](api.md#diagnose-dsl).

## JSON result format

Results are returned as canonical typed JSON: each binding maps a
variable name to `{"type": ..., "value": ...}`, or `null` for a variable
left unbound by an unmatched `optional` block. Exact decimal values are
always JSON strings, to avoid precision loss:

```json
{
  "variables": ["Year", "Count", "Confidence", "CapturedAt"],
  "results": [
    {
      "Year": { "type": "year", "value": "1979" },
      "Count": { "type": "integer", "value": "12" },
      "Confidence": { "type": "decimal", "value": "0.92" },
      "CapturedAt": { "type": "instant", "value": "2026-08-06T12:15:00Z" }
    }
  ],
  "count": 1,
  "total": 1,
  "hasMore": false,
  "truncated": false,
  "warnings": [],
  "language": "dsl",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:..."
}
```

## HTTP: `POST /query`

The request body is a JSON object:

- `"query"` (required): the `find`/`where` query text.
- `"action"` (optional): `"execute"` (default), `"validate"` (check
  without running), `"explain"` (show the structured plan without
  running), or `"diagnose"` (validation plus data-aware diagnostics and
  proven repairs, without running; see
  [API: Diagnose](api.md#diagnose-dsl)).
- `"language"` (optional): may be omitted; the only accepted value is
  `"dsl"`.

```bash
curl -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Artist, Work\nwhere\n  artist(Artist)\n  created(Artist, Work)\nlimit 10"}'
```

A successful `execute` response carries the rows, the paging fields
described under [Pagination](#pagination), any advisory `warnings`, and
`language`/`languageVersion`/`environmentFingerprint` -- so a client can
cache schema knowledge purely from ordinary query responses, without a
separate `/predicates` round trip:

```json
{
  "variables": ["Artist", "Work"],
  "results": [
    { "Artist": { "type": "atom", "value": "tina_keane" }, "Work": { "type": "atom", "value": "she" } }
  ],
  "count": 1,
  "total": 1,
  "hasMore": false,
  "truncated": false,
  "warnings": [],
  "language": "dsl",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:..."
}
```

When the first page of an `execute` is empty, the response also carries
the [`diagnose`](api.md#diagnose-dsl) action's `diagnostics`,
`provablyEmpty` and any proven `repair` (between `warnings` and
`language`), explaining the empty result (for example a misspelled
constant, or `Y > @2090` when no year there is that late) without a
second request. Non-empty results carry none of these fields.

**Two distinct error families** (see also [API Reference](api.md#error-response-shapes)):

- **Query-invalid** (the request was well-formed, but the query itself
  is invalid) -- for `validate`/`explain`, or `execute` on an invalid
  query, HTTP 400 with `"valid": false` and the structured error list
  directly as the response body:

  ```json
  {
    "valid": false,
    "errors": [
      { "code": "unknown_predicate", "message": "Unknown predicate 'artst'; did you mean: artist?", "line": 2, "column": 3, "predicate": "artst", "suggestions": ["artist"] }
    ],
    "warnings": [],
    "language": "dsl",
    "languageVersion": "beingdb-dsl/1",
    "environmentFingerprint": "sha256:..."
  }
  ```

- **Request/runtime failure** (malformed JSON, timeout, an internal
  error, a bad `language`/`action` value, or request-level
  `offset`/`limit` fields) -- always
  `{"error": {"code": ..., "message": ...}}`, an object, never a bare
  string:

  ```json
  { "error": { "code": "malformed_request", "message": "The request body is not valid JSON." } }
  ```

`action: "explain"` returns both a structured `plan` (a list of typed
operation objects: `predicate_scan`, `exact_index_lookup`,
`range_index_lookup`, `join`, `optional_join`, `union`, `not_exists`,
`filter`, `project`, `distinct`, `sort`, `offset`, `limit`) and a
human-readable `planText`, alongside `normalizedCoreQuery` (the
patterns and comparisons the query is lowered to internally, as
strings), without executing the query:

```json
{
  "valid": true,
  "language": "dsl",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:...",
  "projection": ["Person"],
  "distinct": true,
  "normalizedCoreQuery": {
    "patterns": ["director_of(Person, Organisation)", "founded(Organisation, Year)"],
    "comparisons": ["Year > 1950"]
  },
  "plan": [
    { "operation": "range_index_lookup", "predicate": "founded", "argumentPosition": 1, "constraints": [ { "operator": ">", "value": { "type": "integer", "value": "1950" } } ] },
    { "operation": "join", "predicate": "director_of", "argumentPosition": 0, "joinVariables": ["Organisation"] },
    { "operation": "project", "variables": ["Person"] },
    { "operation": "distinct", "variables": ["Person"] }
  ],
  "planText": "founded: range_index(position=1, lower=exclusive:1950)\ndirector_of: equality_index_on_variable(position=1, var=Organisation)"
}
```

The plan is deterministic, typed, and independent of Irmin/Pack
filesystem details -- no storage paths appear in it.

## Predicate introspection: `GET /predicates?detailed=true`

Returns each predicate's argument type signature, fact count, a few
bounded examples and any [declared](#predicate-declarations-optional)
roles, semantic types and description, plus the query environment's
fingerprint:

```bash
curl 'http://localhost:8080/predicates?detailed=true&q=creat'
```

```json
{
  "predicates": [
    {
      "name": "created_by",
      "arity": 2,
      "count": 3,
      "description": "Relates a work to the person who created it.",
      "arguments": [
        { "position": 0, "types": ["atom"], "role": "Work", "semanticType": "work" },
        { "position": 1, "types": ["atom"], "role": "Creator", "semanticType": "person" }
      ],
      "examples": [[{ "type": "atom", "value": "she" }, { "type": "atom", "value": "tina_keane" }]]
    }
  ],
  "environmentFingerprint": "sha256:3a1f...c9",
  "languageVersion": "beingdb-dsl/1"
}
```

`types`, `count` and `examples` are always inferred from the facts.
`description`, `role` and `semanticType` appear only when declared;
undeclared predicates have exactly the fields they had before
declarations existed.

`q` filters by case-insensitive substring match on the predicate name;
`names` filters to an exact comma-separated set of names. The
fingerprint (SHA-256 of a canonical, sort-order-independent encoding of
every predicate's name, arity, observed argument types and any declared
roles, semantic types and description, plus the query-language
version) changes whenever any of those change --
useful for cache invalidation in LLM prompts built from this
introspection data. It is exposed consistently, under the same
`environmentFingerprint` key, in `/predicates`, REPL startup, and every
`POST /query` response -- `execute`, `validate`, `explain` and
`diagnose` alike.

## REPL

The REPL (`beingdb repl` / `beingdb-repl`) reads `find`/`where` queries:
type the lines of a query and finish with a blank line to run it. A line
starting with `:` is a command (`:help` lists them).

```
BeingDB REPL. 6 predicates, fingerprint sha256:3a1f...c9, beingdb-dsl/1. Enter a find/where query (blank line to run), :help for commands, :quit to exit.
beingdb> :environment
predicates: 6
environment_fingerprint: sha256:3a1f2b7c9e4d5a6f8091b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5a6b
language_version: beingdb-dsl/1
beingdb> :describe created_by
created_by/2  (3 facts)
  Relates a work to the person who created it.
  arg 0 Work (work): atom
  arg 1 Creator (person): atom
  examples:
    created_by(she, tina_keane)
beingdb> find Work
...> where
...>   created(_, Work)
...> limit 3
...>
{
  "variables": [ "Work" ],
  "results": [ { "Work": { "type": "atom", "value": "she" } } ],
  "count": 1,
  "total": 1,
  "hasMore": false,
  "truncated": false,
  "warnings": [],
  "language": "dsl",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:3a1f...c9"
}
```

`:explain`, `:validate` and `:diagnose` each read a query the same way
(blank line to finish) and show its plan, its validation result, or the
`diagnose` action's diagnostics and proven repairs, without executing
it. `:explain find ...` also works, with the rest of the query entered
on the following lines.

`:load <file>` (or `:loadqueries <file>`) runs a file of queries.
Queries are separated by blank lines, and lines starting with `%` or
`#` are comments:

```
% Works by tina_keane
find Work
where
  created(tina_keane, Work)

# Where were they shown?
find Work, Exhibition
where
  created(tina_keane, Work)
  shown_in(Work, Exhibition)
```

For `.pl`, `.pro` and `.facts` files, `:load` loads facts instead. See
[Getting Started](getting-started.md#interactive-repl) for the full
command list.

## Full example

```prolog
person(alice_smith).
label(alice_smith, "Alice Smith"@en).
birth_year(alice_smith, @1972).
confidence(assertion_1, 0.92).

capture(capture_1).
captured_at(
  capture_1,
  @2022-08-17T12:30:00Z
).
target_uri(
  capture_1,
  <https://example.org/about>
).
```

Query -- captures within 2022, using the instant range index on
`captured_at`'s second argument:

```
find Capture, Date
where
  captured_at(Capture, Date)
  Date >= @2022-01-01T00:00:00Z
  Date < @2023-01-01T00:00:00Z
```

```bash
curl -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Capture, Date\nwhere\n  captured_at(Capture, Date)\n  Date >= @2022-01-01T00:00:00Z\n  Date < @2023-01-01T00:00:00Z"}'
```

```json
{
  "variables": ["Capture", "Date"],
  "results": [
    {
      "Capture": { "type": "atom", "value": "capture_1" },
      "Date": { "type": "instant", "value": "2022-08-17T12:30:00Z" }
    }
  ],
  "count": 1,
  "total": 1,
  "hasMore": false,
  "truncated": false,
  "warnings": [],
  "language": "dsl",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:..."
}
```

## Best practices

1. **Order doesn't matter** -- BeingDB plans the `where` lines itself.
2. **Use constants and comparisons** -- they drive positional indexes
   instead of a full scan.
3. **Use `limit` (and `order by` when paging)** -- keeps responses small
   and pages stable.
4. **Validate or diagnose generated queries** -- the `validate` and
   `diagnose` actions catch mistakes without running the query.
5. **Keep predicates simple** -- one relationship type per predicate.
6. **Consistent arity** -- all facts for a predicate must have the same
   number of arguments.

## Further reading

- [Internals](internals.md) -- typed value model, storage layout, fact
  IDs, index encoding, comparison semantics, and current limitations.
  Internally, BeingDB lowers each `find`/`where` query to a core
  pattern form (the patterns and comparisons shown in `explain`'s
  `normalizedCoreQuery`) that the planner and executor run. That core
  form is not a public query language: `"language": "core"` is rejected
  with `unsupported_language`.
- [API Reference](api.md)
- [Installation Guide](installation.md)
