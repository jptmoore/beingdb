# BeingDB Query Language

BeingDB has two query languages that share one planner and executor:

- The **core query language**: a typed, Prolog-style pattern language
  (predicate patterns, joins, comparisons). This is the low-level model
  everything else compiles down to. Documented first, below.
- The **expressive query language**: a line-oriented `find`/`where`
  syntax for programmatic, interactive, and LLM/RAG use, adding
  projection, `optional`, `either`/`or`, `not`, `order by`, `limit`,
  `offset`, `distinct`, and dataset-aware validation on top of the same
  core patterns and comparisons. See
  [Expressive Query Language](#expressive-query-language) below.

Both languages lower into the same structured AST and run through the
same planner and executor -- there is no separate execution path for
either.

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
  required or supported.

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

## Query terms

| Type | Syntax | Example | Description |
|------|--------|---------|-------------|
| **Variable** | Uppercase | `Work`, `Year` | Binds to a typed value during matching |
| **Wildcard** | `_` | `_` | Matches anything, not bound |
| **Literal** | any typed literal from the table above | `tina_keane`, `"text"`, `1979`, `@1979`, `<https://x>` | Exact-match constant of that type |

## Query patterns

### Whitespace and formatting

Whitespace (spaces, tabs, newlines) between tokens is insignificant.
Commas are what combine clauses and predicate arguments. A query may
therefore be written on one line, one clause per line, or with a
predicate's arguments spread across several lines -- all of the
following are equivalent:

```prolog
created(Artist, Work), shown_in(Work, Exhibition)
```

```prolog
created(Artist, Work),
shown_in(Work, Exhibition)
```

```prolog
created(
  Artist,
  Work
),
shown_in(
  Work,
  Exhibition
)
```

This makes single-line queries convenient for REST clients, which never
need to escape or inject newlines:

```bash
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition)"}'
```

The core parser (used by the REST API, the REPL, and the CLI -- there
is no separate parsing path for any of them) only treats whitespace as
significant inside quoted strings, so a comma inside a string literal
is never mistaken for a clause separator:

```prolog
title(Work, "Smith, Jones and Brown")
```

Malformed input (unmatched parentheses, duplicate separators, or an
incomplete comparison) is rejected with a descriptive parse error
rather than being silently misinterpreted.

### Single pattern

```bash
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work)"}'
```

### Multiple patterns (joins)

Comma-separated patterns join on shared variables:

```bash
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition)"}'
```

Joins can chain across more than two patterns, following a variable
through several relationships:

```prolog
created(Artist, Work),
shown_in(Work, Exhibition),
held_at(Exhibition, Venue)
```

This follows the factual chain `Artist -> Work -> Exhibition -> Venue`
without requiring those relationships to be reconstructed from
unstructured text.

### Typed literals in patterns

```prolog
created(Work, @1979)
captured_at(Capture, @2026-08-06T12:15:00Z)
homepage(Organisation, <https://example.org/>)
label(Person, "Alice Smith")
```

### Wildcards and constants

```prolog
created(Artist, _)
created(tina_keane, Work)
```

## Comparisons

In addition to predicate patterns, a query may contain typed comparison
clauses. The parser builds a structured AST for these
(`Query_ast.Compare` / `Query_ast.Between`); they are never interpreted
from text at execution time.

```
=   !=   <   <=   >   >=   between ... and ...
```

Examples:

```prolog
birth_year(Person, Year),
Year >= 1900,
Year < 1950
```

```prolog
confidence(Assertion, Score),
Score >= 0.8
```

```prolog
captured_at(Capture, Date),
Date between @2019-01-01 and @2019-12-31
```

`between LOWER and UPPER` is inclusive at both ends.

### Equality is type-aware

```prolog
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
promoted (so `birth_year(Person, Year), Year >= 1900` works with a bare
integer bound); this promotion is intentionally narrow and does **not**
extend to `date` or `year_month` -- a year is never silently treated as
a date.

Temporal comparisons across genuinely different temporal types are
rejected:

```prolog
@1979 < @1979-04-01   % rejected: year vs date
```

Invalid comparisons return a descriptive error instead of silently
filtering results, for example:

```
Cannot compare a date with an integer.

Left value: @1979-04-01
Right value: 1979

Did you mean @1979 (year only) or @1979-04-01 (full date)?
```

The expressive query language additionally catches many of these
**statically**, at validation time, whenever a variable's type can be
inferred from the predicate patterns that bind it (see
[Validation](#validation) below) -- so a query comparing a `date`-typed
variable against an integer literal is rejected with a structured
`comparison_type_mismatch` error before it ever runs, not just when a
matching row happens to be evaluated.

## Query planning

BeingDB does not fall back to "scan everything, then filter" whenever a
positional index can answer a comparison directly. For:

```prolog
captured_at(Capture, Date),
Date >= @2019-01-01,
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
nested scan of every fact.

When no pattern argument is a literal or a comparison-constrained
variable, execution falls back to a full predicate scan (still
per-predicate, not across the whole store). See
[internals.md](internals.md#43-range-lookup-and-its-documented-limitation)
for the current limitation of range scans (correct, but not yet a true
sorted binary search).

## Pagination

Add `offset` and `limit` for paginated results:

```bash
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work)", "offset": 0, "limit": 10}'
```

Response includes pagination metadata:
```json
{
  "variables": ["Artist", "Work"],
  "results": [...],
  "count": 10,
  "total": 156,
  "offset": 0,
  "limit": 10
}
```

**For joins with pagination:**
- First pass: stream through all results to count total.
- Second pass: stream to offset and return page.
- Memory-efficient for large result sets.

## Query protections

Built-in safety limits prevent runaway or malicious queries, all
configurable per-server without recompiling (see
[Safety limits](api.md#safety-limits) for the config file and defaults):

- **Timeout:** 5 seconds maximum execution time by default.
- **Intermediate results:** 10,000 row limit during joins by default.
- **Result limit:** 1000 by default, via `--max-results` or the config
  file's `max_results`.
- **Query length:** 20,000 bytes by default; longer raw query strings
  are rejected (`query_too_long`, HTTP 413) before parsing.
- **Concurrency:** 20 simultaneously in-flight queries by default;
  further requests get `server_busy` (HTTP 429) until one finishes.
- **Connectivity:** a query's predicate patterns must form a single
  connected component -- every pattern must be reachable from every
  other one through a shared variable, a shared constant, or a
  comparison that references both. This applies to *both* languages.

  Repeated predicates are always fine, including self-joins and
  multi-hop chains:

  ```prolog
  parent(Person, Parent), parent(Parent, Grandparent)
  ```

  What's rejected is a genuinely **disconnected** query -- one that
  would compute an unconstrained Cartesian product because two pattern
  groups share nothing:

  ```prolog
  person(Person), organisation(Organisation)   % rejected: no join between them
  ```

  ```prolog
  person(Person), works_for(Person, Organisation), organisation(Organisation)   % fine: joined
  ```

  An `optional`/`either`-`or`/`not` group counts as connected if it
  shares a variable with the rest of the query; each `either`/`or`
  branch is additionally checked for its own internal connectivity. A
  disconnected query is rejected with a `disconnected_query` error (see
  [Validation](#validation)).

## What the core query language does NOT support

The patterns/joins/comparisons above are the whole core language. It has
no projection, ordering, negation, disjunction, or deduplication of its
own -- those are provided by the expressive query language (below),
which lowers into extra clause shapes (`optional`, `either`/`or`, `not`)
that the *same* core AST, planner, and executor already understand.

- **Aggregation:** no `COUNT`, `SUM`, `GROUP BY`, in either language.
- **Arithmetic:** no `Y = X + 1`, in either language.
- **Recursion:** no transitive closure or path queries, in either
  language.
- **Functions:** no computed values or transformations.
- **Uncertain dates or date intervals.**
- **A user-authored schema** -- types are always inferred, never
  declared.

## JSON result format

Results are returned as canonical typed JSON: each binding maps a
variable name to `{"type": ..., "value": ...}`. Exact decimal values are
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
  "total": 1
}
```

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

```prolog
captured_at(Capture, Date),
Date >= @2022-01-01T00:00:00Z,
Date < @2023-01-01T00:00:00Z
```

```bash
curl -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "captured_at(Capture, Date), Date >= @2022-01-01T00:00:00Z, Date < @2023-01-01T00:00:00Z"}'
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
  "total": 1
}
```

## Best practices

1. **Order doesn't matter** -- BeingDB optimizes automatically.
2. **Use constants and comparisons** -- they drive positional indexes
   instead of a full scan.
3. **Always use `limit` for joins** -- prevents timeouts on large
   datasets.
4. **Keep predicates simple** -- one relationship type per predicate.
5. **Consistent arity** -- all facts for a predicate must have the same
   number of arguments.

## Expressive Query Language

The expressive query language is a line-oriented `find`/`where` syntax
intended for programmatic use, interactive querying, and LLM-driven RAG
workflows. It reuses exactly the same predicate patterns, literals, and
comparisons documented above, and lowers into the same core AST that the
one planner and executor already run -- it adds projection, optional
matches, alternatives, negation, ordering, deduplication, and pagination,
plus dataset-aware validation (unknown predicates, arity, literal type
checks) with helpful error messages.

### Syntax

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

- `find` lists the variables to project, in order; `distinct` deduplicates
  the projected rows.
- `where` introduces the clause list: predicate patterns, comparisons, and
  `between ... and ...`, exactly as in the core language.
- `optional` is a left join: clauses inside it may fail to match without
  discarding the row -- unmatched variables come back unbound (`null` in
  JSON).
- `either` / `or` is disjunction: at least one branch must match; each
  branch's bindings contribute a row (a union, not a join, across
  branches).
- `not` is negation-as-failure: the enclosing row is kept only if the
  nested clauses produce *no* matches. Every variable used inside `not`
  must also be bound by a positive clause elsewhere in the query (a
  variable that is *only* ever mentioned inside a negation is rejected as
  an `unsafe_negation` validation error, since its value would otherwise
  be unconstrained).
- `order by`, `limit`, and `offset` apply to the final, projected result
  set (after `optional`/`either`/`not` have been resolved), not to any one
  clause.
- Blank lines and lines starting with `%` or `#` are ignored.
- Year literals need the `@` prefix (`@1972`), exactly as in the core
  language -- a bare `1972` is an integer, not a year, and comparing it
  against a `year`-typed argument is a validation error.

### Unbound optional variables: one stable JSON shape

Every projected variable appears as a key in every result row, whether
or not an `optional` branch actually matched -- an unmatched variable is
`null`, it is never simply omitted from the row:

```json
{ "Person": { "type": "atom", "value": "alice" }, "Label": null }
```

This is the same shape everywhere a result row is produced: `execute`
responses for both languages, and the REPL's printed JSON. `distinct`
treats two `null`s in the same position as equal (so rows differing
only by an unmatched optional variable are still deduplicated
together). `order by` on a variable that's `null` in some rows uses a
fixed policy -- **nulls last**, for both `ascending` and `descending` --
so ordering is deterministic regardless of how many rows have an
unmatched optional value.

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

### Validation

Every expressive query is validated against a **query environment**
built from the compiled store's inferred per-predicate schema (arity,
per-argument-position observed types, fact counts, and a few bounded
examples) -- no user-authored schema is read or required. Validation
reports *every* problem found, not just the first, as a list of
structured errors, each with a stable `code` and a human-readable
`message`, plus `line`/`column` where applicable:

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

### HTTP: `POST /query` with `language` and `action`

The same endpoint used for the core language accepts two additional
optional fields:

- `"language"`: `"core"` (default) or `"dsl"`.
- `"action"`: `"execute"` (default), `"validate"` (check without
  running), or `"explain"` (show the structured plan without running).

```bash
curl -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{
    "language": "dsl",
    "query": "find Artist, Work\nwhere\n  artist(Artist)\n  created(Artist, Work)\nlimit 10"
  }'
```

A successful `execute` response looks like the core language's, plus any
advisory `warnings`, plus `language`/`languageVersion`/
`environmentFingerprint` (see below) -- so a client can cache schema
knowledge purely from ordinary query responses, without a separate
`/predicates` round trip:

```json
{
  "variables": ["Artist", "Work"],
  "results": [
    { "Artist": { "type": "atom", "value": "tina_keane" }, "Work": { "type": "atom", "value": "she" } }
  ],
  "count": 1,
  "warnings": [],
  "language": "dsl",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:..."
}
```

**Two distinct error families** (see also [API Reference](api.md#error-response-shapes)):

- **Query-invalid** (the request was well-formed, but the query itself
  is invalid) -- for `validate`/`explain`, or `execute` on an invalid
  query, either language returns HTTP 400 with `"valid": false` and the
  structured error list directly as the response body:

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
  error, or a bad `language`/`action` value) -- always
  `{"error": {"code": ..., "message": ...}}`, an object, never a bare
  string:

  ```json
  { "error": { "code": "malformed_request", "message": "The request body is not valid JSON." } }
  ```

`action: "explain"` returns both a structured `plan` (a list of typed
operation objects: `predicate_scan`, `exact_index_lookup`,
`range_index_lookup`, `join`, `optional_join`, `union`, `not_exists`,
`filter`, `project`, `distinct`, `sort`, `offset`, `limit`) and a
human-readable `planText`, alongside `normalizedCoreQuery` (the lowered
query's patterns and comparisons as strings), without executing the
query:

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

### Predicate introspection: `GET /predicates?detailed=true`

Returns each predicate's argument type signature, fact count, and a few
bounded examples, plus the query environment's fingerprint:

```bash
curl 'http://localhost:8080/predicates?detailed=true&q=creat'
```

```json
{
  "predicates": [
    {
      "name": "created",
      "arity": 2,
      "count": 3,
      "arguments": [
        { "position": 0, "types": ["atom"] },
        { "position": 1, "types": ["atom"] }
      ],
      "examples": [[{ "type": "atom", "value": "tina_keane" }, { "type": "atom", "value": "she" }]]
    }
  ],
  "environmentFingerprint": "sha256:3a1f...c9",
  "languageVersion": "beingdb-dsl/1"
}
```

`q` filters by case-insensitive substring match on the predicate name;
`names` filters to an exact comma-separated set of names. The
fingerprint (SHA-256 of a canonical, sort-order-independent encoding of
every predicate's name, arity, and observed argument types, plus the
expressive-language version) changes whenever any of those change --
useful for cache invalidation in LLM prompts built from this
introspection data. It is exposed consistently, under the same
`environmentFingerprint` key, in `/predicates`, REPL startup, and every
`POST /query` response -- `execute`, `validate`, and `explain` alike,
both languages.

### REPL

The REPL (`beingdb repl` / `beingdb-repl`) has three modes, switched with
`:core`, `:dsl`, and `:auto` (the default): `:auto` detects the
expressive language when a query starts with `find`, and otherwise uses
the core language. In `:dsl` mode (or when auto-detected as `dsl`), the
REPL keeps reading lines until a blank line finishes the query, since the
expressive syntax spans multiple lines.

```
beingdb> :environment
predicates: 6
environment_fingerprint: sha256:3a1f2b7c9e4d5a6f8091b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5a6b
language_version: beingdb-dsl/1
mode: auto
beingdb> :describe created
created/2  (3 facts)
  arg 0: atom
  arg 1: atom
  examples:
    created(tina_keane, she)
beingdb> find Work
where
  created(_, Work)
limit 3

{
  "variables": [ "Work" ],
  "results": [ { "Work": { "type": "atom", "value": "she" } } ],
  "count": 1,
  "warnings": []
}
```

`:validate` reads a query the same way (blank line to finish) and reports
validation results without executing it.

## Further reading

- [Internals](internals.md) -- typed value model, storage layout, fact
  IDs, index encoding, comparison semantics, and current limitations.
- [API Reference](api.md)
- [Installation Guide](installation.md)

