# BeingDB Internals

This document describes BeingDB's typed value model, canonical encoding,
storage layout and query planning.

## 1. The typed value model

`lib/value.ml` defines the one authoritative value type:

```ocaml
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
```

This same type is used for: source parsing (`Lexer`, `Parse_predicate`),
compiled facts (`Fact.t`), query literals and bindings (`Query_ast`,
`Query_engine`), comparison logic (`Value.order_compare`), storage
encoding (`Fact.encode`, `Pack_backend`), and API/JSON serialization
(`Value.to_json`).

Numbers, dates and other literals are never stored as OCaml `float`.
Exact decimals are represented as a coefficient and scale
(`lib/decimal.ml`); calendar dates and UTC instants are computed with a
proleptic-Gregorian day-count algorithm (`lib/calendar.ml`), using only
the OCaml standard library.

### 1.1 Literal syntax

| Type          | Syntax                              | Example                              |
|---------------|--------------------------------------|---------------------------------------|
| Atom          | bare lowercase identifier            | `alice_smith`                          |
| String        | double-quoted                        | `"Alice Smith"`                        |
| Lang_string   | double-quoted + `@tag`                | `"Alice Smith"@en`                     |
| Integer       | optional `-`, digits                  | `1972`, `-42`                          |
| Decimal       | digits `.` digits                     | `0.92`, `-3.50`                        |
| Boolean       | `true` / `false` (reserved words)     | `true`                                 |
| Year          | `@YYYY`                               | `@1972`                                |
| Year_month    | `@YYYY-MM`                            | `@1972-05`                             |
| Date          | `@YYYY-MM-DD`                         | `@1972-05-14`                          |
| Instant       | `@YYYY-MM-DDTHH:MM:SS[.fff](Z\|±HH:MM)` | `@2026-08-06T12:15:00Z`              |
| Uri           | `<...>`                               | `<https://example.org/>`               |
| Variable (query only) | leading uppercase              | `Person`, `Year`                       |
| Wildcard (query only)  | `_`                             | `_`                                     |

`1979` (integer), `@1979` (year), `"1979"` (string) and `year_1979`
(atom) are four different values of four different types; they are
never equal to one another (see ["Comparison semantics"](#4-comparison-semantics)).

Tokenizing is centralized in `lib/lexer.ml` and shared by fact parsing
(`Parse_predicate`) and query parsing (`Query_parser`), so both accept
exactly the same literal syntax.

### 1.2 Validation and normalization

Performed while constructing a `Value.t` (in `Value.ml` and `Calendar.ml`):

- **Dates**: `Calendar.valid_date` rejects out-of-range months/days,
  correctly accounting for leap years (`is_leap_year`).
- **Year-months**: `Calendar.valid_year_month` requires `1 <= month <= 12`.
- **Instants**: `Calendar.parse_instant` requires a `T` time separator and
  a zone designator (`Z` or `±HH:MM`); the local time is converted to UTC
  seconds-since-epoch (`Calendar.instant = { seconds : int64; nanos :
  int }`) using the same proleptic-Gregorian day-count algorithm as
  dates, so instants and dates share one calendar implementation.
- **URIs**: `Value.valid_uri` requires an RFC 3986-shaped scheme
  (`letter (letter | digit | + | - | .)* ":"`) and rejects whitespace and
  angle brackets. This is a syntactic check, not a full RFC 3986 parser.
- **Language tags**: `Value.valid_language_tag` requires a 2-8 letter
  primary subtag, optionally followed by `-`-separated 1-8 character
  alphanumeric subtags -- a reasonable approximation of BCP 47, not a
  full implementation (no registry validation).
- **Decimals**: `Decimal.of_string`/`Decimal.make` canonicalize by
  stripping trailing zero digits from the fractional part, so `0.9`,
  `0.90` and `0.900` all produce the identical `Decimal.t` and print
  identically (`Decimal.to_string`).

`@1979` and `@1979-01-01` are never interchangeable: `Year` and `Date`
are distinct constructors, and no code path converts between them.

## 2. Canonical fact encoding and fact IDs

`lib/fact.ml` defines:

```ocaml
type t = { predicate : string; arguments : Value.t list }
```

**Canonical proposition** (used only to derive the fact ID -- evidence,
editorial metadata and source information are not modeled and therefore
cannot appear in it):

```
<predicate>/<arity>|<type_1>:<canonical_1>|<type_2>:<canonical_2>|...
```

**Fact ID** = `Digestif.SHA256.to_hex (Digestif.SHA256.digest_string canonical_proposition)` --
deterministic and stable across builds because it depends only on the
canonical typed proposition. Because the type tag is part of the input:

```
value(item, 1979).      -> "integer:1979"
value(item, @1979).     -> "year:1979"
value(item, "1979").    -> "string:1979"
```

produce three different fact IDs.

**Stored encoding** (`Fact.encode`/`Fact.decode`, used as the value at
`/facts/<fact-id>`) is a simple length-prefixed format immune to
delimiter collisions:

```
<len>:<predicate><len>:<arity-as-string>(<len>:<type><len>:<canonical>)*
```

## 3. Storage layout (Irmin Pack)

```
/facts/<fact-id>                                     -> canonical encoded fact
/index/<predicate>/_all/<fact-id>                     -> "" (full-predicate scan bucket)
/index/<predicate>/<position>/<type>/<key>/<fact-id>  -> "" (positional index)
/meta/<predicate>                                     -> JSON schema manifest
```

The complete typed fact is stored exactly once, at `/facts/<fact-id>`.
Every index entry is just a pointer (an empty leaf) back to that ID, so
a fact's canonical representation never needs to be duplicated per
index.

For example:

```prolog
captured_at(capture_1, @2026-08-06T12:15:00Z).
```

produces conceptually:

```
fact:
  /facts/<id> -> captured_at(atom:capture_1, instant:2026-08-06T12:15:00Z)

indexes:
  /index/captured_at/_all/<id>
  /index/captured_at/0/atom/capture_1/<id>
  /index/captured_at/1/instant/2026-08-06T12:15:00Z.000000000/<id>
```

### 3.1 Index keys

`Value.index_key` computes the path segment used under `<key>`:

- For ordered types (`Integer`, `Decimal`, `Year`, `Year_month`, `Date`,
  `Instant`), it is `Value.sortable_string`: a fixed-width, sign-aware
  encoding built so that byte-wise string comparison matches the type's
  natural order (`Value.order_compare`). Signed integers use the
  standard "XOR the sign bit, print as unsigned fixed-width decimal"
  trick (`Int64.logxor n Int64.min_int`), so negative and positive
  integers sort correctly in one contiguous range. Dates and instants
  are encoded from a single, fixed-width integer (days, respectively
  seconds, since the Unix epoch), so they too are fixed-width and
  correctly ordered.
- For non-ordered types (`Atom`, `String`, `Lang_string`, `Boolean`,
  `Uri`), it is the canonical string.
- Any key longer than 200 bytes is replaced by a SHA-256 hash
  (`"h:" ^ Digestif.SHA256.to_hex ...`) to keep index path segments
  bounded; every lookup re-verifies the fully decoded fact against the
  query value (`Value.equal` / `Value.order_compare`), so a hash
  collision could only ever cause an unnecessary extra comparison,
  never an incorrect result.

### 3.2 Equality lookup

`Pack_backend.equality_lookup store predicate position value` computes
`Value.index_key value` and lists
`/index/<predicate>/<position>/<type_name value>/<key>/`, whose children
are exactly the matching fact IDs -- a direct, non-scanning lookup. The
fetched facts are still re-checked against `value` with `Value.equal`
before being returned, as a defense against the (extremely unlikely)
case of a hash collision on a long key.

### 3.3 Range lookup and its documented limitation

`Pack_backend.range_lookup store predicate position ~lower ~upper`
enumerates every distinct index key under the relevant type branch(es)
(the bound's own numeric/temporal family, plus every type actually
observed at that position, from the schema manifest), fetches the
corresponding facts, and checks each one exactly with
`Value.order_compare`.

**This does not currently perform a true sorted binary-searchable range
scan.** Irmin-Pack's inode representation orders large directories by a
seeded hash of the step name (`inode_child_order = \`Seeded_hash`) rather
than by lexicographic order of the step itself, so listing a directory
does not yield sorted output even though the keys themselves are
lexicographically sortable by construction. Range lookups therefore
scan every key in the relevant type branch(es) -- bounded by the number
of *distinct values* at that argument position, not by the total number
of facts for the predicate. The index keys are stored using a
fixed-width, lexicographically sortable encoding (see 3.1), so a genuine
sorted range scan could be added on top of the existing on-disk layout;
only the traversal strategy is not yet optimal.

A comparison between two *ordered* types that are not mutually
compatible (e.g. a `Date` argument compared against an `Integer`
literal) is treated as a genuine error and aborts the query (see
["Comparison semantics"](#4-comparison-semantics)) rather than silently
returning zero rows; a comparison against a *non-ordered* type sharing a
mixed-type position (e.g. a `String` sharing a position with `Integer`
values) is silently excluded, matching the schema-inference design
below.

## 4. Comparison semantics

`Value.equal` is fully type-aware: values of different types are never
equal, even when their canonical text coincides
(`1979 <> @1979 <> "1979" <> year_1979`).

`Value.order_compare` supports ordering only between compatible types:

| Left       | Right      | Supported | Notes |
|------------|------------|-----------|-------|
| `integer`  | `integer`  | yes       | |
| `decimal`  | `decimal`  | yes       | exact, via `Decimal.compare` |
| `integer`  | `decimal`  | yes       | integer promoted to decimal (scale 0) |
| `year`     | `year`     | yes       | |
| `integer`  | `year`     | yes       | narrow promotion, see below |
| `year_month` | `year_month` | yes   | |
| `date`     | `date`     | yes       | |
| `instant`  | `instant`  | yes       | |
| `year`     | `date`     | **no**    | never silently converted |
| everything else | | **no** | e.g. two atoms, two strings, two booleans, two URIs are only `=`/`!=`-comparable, not orderable |

The `integer`/`year` promotion lets a bare integer literal be compared
against a `year`-typed variable (e.g.
`birth_year(Person, Year), Year >= 1900`), the same way `integer`
promotes to `decimal`. It is narrow: it never applies to `date` or
`year_month`.

An incompatible comparison raises a descriptive error rather than
silently filtering, for example:

```
Cannot compare a date with an integer.

Left value: @1979-04-01
Right value: 1979

Did you mean @1979 (year only) or @1979-04-01 (full date)?
```

## 5. Query language, planning and execution

See [query-language.md](query-language.md) for the user-facing syntax
and semantics. In summary:

- `lib/query_ast.ml` defines the structured AST (`term`, `clause`,
  `comparison_operator`) produced by `lib/query_parser.ml`; comparisons
  are never re-interpreted from text during execution. `clause` also
  has three *group* variants -- `Optional`, `Alternatives`, and
  `Not_exists`, each holding a nested `clause list` (or, for
  `Alternatives`, a `clause list list`, one per branch) -- used to
  express the expressive query language's `optional`/`either`-`or`/`not`
  (see section 6). The core predicate-pattern parser never produces
  these directly; only `Dsl_lower` does, so the core language's surface
  syntax is unchanged.
- The core language's grammar (approximately):

  ```
  query       := clause ("," clause)*
  clause      := pattern | comparison | between
  pattern     := IDENT "(" (term ("," term)*)? ")"
  comparison  := term OP term            OP ::= = | != | < | <= | > | >=
  between     := term "between" term "and" term
  term        := VARIABLE | "_" | literal
  ```

  Tokenization (`lib/lexer.ml`) and clause-level parsing
  (`lib/clause_parser.ml`, shared with the expressive language) are
  separate passes: the lexer turns the input into a flat token stream
  first, skipping `[' ' '\t' '\r' '\n']+` between tokens (so formatting
  never affects meaning), then `Query_parser` splits that stream on
  top-level commas (commas nested inside a pattern's own parentheses
  are not top-level) and parses each group into a `clause`. Whitespace
  is only ever significant inside a quoted string literal, where the
  lexer consumes characters (including commas) up to the closing `"`
  before resuming normal tokenization -- this is what lets
  `title(Work, "Smith, Jones and Brown")` parse as a single two-argument
  pattern rather than being split on the embedded comma.
  `Query_parser.parse_query_result : string -> (query, string) result`
  is the single entry point used by the REST API (`Controller`), the
  REPL (`Cli_repl`), and the CLI -- there is no separate parsing path
  per consumer.
- `lib/query_planner.ml` is pure (it never touches the store): it
  collects every `Compare`/`Between` clause that constrains a variable
  with a literal (normalizing `literal OP variable` to `variable OP'
  literal`, and expanding `between` into two constraints), then for each
  predicate pattern (processed in a selectivity order, most-constrained
  first) picks one access method per argument position:
  - `Equality_index` when the position holds a literal, or the
    position's variable has an `=` constraint;
  - `Range_index` when the position's variable has `<`/`<=`/`>`/`>=`/
    `between` constraints;
  - `Equality_index_on_variable` when the position's variable was
    already bound by an earlier pattern in the plan (a join, resolved
    to a concrete value at execution time and looked up via the
    equality index, so joins are index lookups too, not nested full
    scans);
  - `Full_scan` otherwise.

  A group clause plans its nested clause list(s) recursively, with a
  *copy* of the enclosing scope's bound-variable set: variables bound
  only inside an `Optional`/`Alternatives`/`Not_exists` group never leak
  out to the enclosing scope's planning decisions, a deliberately
  conservative safety choice.
- `lib/query_engine.ml` executes the plan: for every candidate fact
  fetched via the chosen access method, it re-verifies **every**
  argument position (constants, joined variables, and range/equality
  constraints) against the fully decoded fact before binding free
  variables -- so an imperfect planning decision can only be slower,
  never incorrect. After all patterns in a query are satisfied, every
  original `Compare`/`Between` clause (including ones that could not
  drive an index, such as comparisons between two joined variables) is
  re-evaluated against the final bindings as a post-filter; the first
  clause that raises a type-mismatch aborts the whole query with that
  error. Group steps execute as: `Optional_step` -- a left join (falls
  through with the row unchanged if the nested group yields no
  matches); `Alternatives_step` -- a union of every branch's
  contributions; `Not_exists_step` -- negation-as-failure (the row
  passes through unchanged only if the nested group yields *no*
  matches).
- `Query_engine.explain : Query_ast.query -> string` renders the chosen
  access method per pattern (recursively, with indentation, for nested
  groups), e.g.:

  ```
  opened: range_index(position=1, lower=2019-01-01, upper=exclusive:2020-01-01)
  artist: full_scan
  optional:
    nationality: full_scan
  ```

  It is available both internally (to tests) and via `POST /query` with
  `"action": "explain"` (either language -- see section 6 and
  [query-language.md](query-language.md)).

## 6. Expressive query language and query environment

The expressive query language (`find`/`where`/...) is a *surface*
syntax that lowers into the same `Query_ast.query` the core language
produces, plus a thin wrapper (`Core_query.t`) carrying the
post-execution directives the core AST has no concept of: `projection`,
`distinct`, `order_by`, `limit`, `offset`. There is exactly one planner
and executor underneath either language.

Pipeline, module by module:

- `lib/clause_parser.ml` -- leaf-clause parsing (a predicate pattern, a
  comparison, or a `between`), factored out of `lib/query_parser.ml` so
  both the core parser and the expressive parser accept identical
  literal/clause syntax with no duplication.
- `lib/surface_ast.ml` -- the parsed form of the expressive syntax,
  before validation: leaf clauses carry a source line number and column
  (for precise error locations), alongside `Optional`/`Alternatives`/
  `Negation` group variants.
- `lib/dsl_parser.ml` -- a line-oriented parser for `find`/`where`/
  `optional`/`either`/`or`/`not`/`order by`/`limit`/`offset`, producing
  a `Surface_ast.surface_query`. Tracks each significant line's 1-based
  line number and the 1-based column of its first non-whitespace
  character, threaded onto every leaf clause.
- `lib/query_environment.ml` -- dataset-aware predicate metadata used
  for validation and introspection, built deterministically from the
  compiled store's per-predicate manifests (section 7) via
  `Pack_backend.list_predicates`/`get_manifest`/`sample_facts` -- no
  separate cache or user-authored schema. Includes a fingerprint:
  `"sha256:" ^ Digestif.SHA256.to_hex (Digestif.SHA256.digest_string
  canonical)` over sorted predicate names, arities, observed argument
  types, and the expressive-language version string
  (`Query_environment.language_version`, currently `"beingdb-dsl/1"`).
  `digestif` (already present transitively via `irmin-git`) is used
  directly rather than hand-rolling SHA-256; fact IDs and long index
  keys (section 2) also moved from MD5 to `Digestif.SHA256` once
  `digestif` was already a dependency, so the whole store now uses one
  hash algorithm throughout. This is a breaking on-disk format change --
  existing compiled `pack_store` directories must be recompiled from
  Git after upgrading.
- `lib/predicate_suggest.ml` -- deterministic "did you mean" suggestions
  for an unknown predicate name (normalized-name equality, Levenshtein
  edit distance, underscore-token overlap, arity compatibility) -- no
  embeddings or external calls.
- `lib/query_connectivity.ml` -- checks that a query's positive
  (non-negated) pattern clauses form a single connected component,
  replacing an earlier, cruder rule that rejected any repeated
  predicate. Two top-level clauses are connected when they share a
  variable, share an identical literal constant, or are both referenced
  by one comparison/between clause; `Optional`/`Alternatives`/
  `Not_exists` groups are each one node (keyed by every variable used
  anywhere inside), and are additionally checked for their own internal
  connectivity recursively (each `either`/`or` branch independently).
  Used by both `Query_validation.validate_query` (so raw core-language
  text is protected too) and `Dsl_lower.lower` (for the structured
  `disconnected_query` error). Self-joins and multi-hop chains sharing a
  variable (`parent(A, B), parent(B, C)`) are always connected and never
  rejected.
- `lib/dsl_lower.ml` -- validates a `Surface_ast.surface_query` against
  a `Query_environment.t` and, if there are no errors, lowers it into a
  `Core_query.t`. Collects *every* problem found (not just the first).
  Checks: unknown predicates (with suggestions), arity, literal-vs-
  observed-type mismatches (a literal type not seen at that argument
  position anywhere in the compiled data is a hard error; a
  heterogeneous position where the literal matches one of several
  observed types is only a warning), unbound `find`/`order by`
  variables, "safe negation" (every variable used inside a `not` block
  must be bound by some positive clause elsewhere in the query),
  connectivity (via `Query_connectivity`), and -- for `<`/`<=`/`>`/`>=`/
  `between` only, never `=`/`!=`, which are always well-defined across
  types -- static comparison-type mismatches: every variable's possible
  type set is inferred as the union of observed types at every argument
  position it's used in (via `Query_environment`), and a comparison is
  flagged if *no* combination of the two sides' types could ever be
  ordered (`Value.order_compatible_types`, a type-name-only mirror of
  `Value.order_compare`'s cases). A variable whose type can't be
  inferred (never bound by a recognized pattern) is left unchecked here,
  deferred to `Query_engine`'s runtime type-checked comparison
  evaluator, exactly as cross-variable comparisons already are.
- `lib/validation_error.ml` -- the structured error/warning type shared
  by validation failures, with `to_json`/`warning_to_json` for the HTTP
  and REPL surfaces. JSON field names are camelCase (`leftType`,
  `rightType`, `argumentPosition`, `expectedTypes`, `receivedType`) to
  match the rest of the normalized `/query` response envelope; the
  `code` *value* itself stays a stable snake_case string.
- `lib/explain_plan.ml` -- builds the structured, machine-readable
  `plan` array for `action: "explain"`: the planner's steps (recursively
  for nested groups) mapped to stable operation names
  (`predicate_scan`/`exact_index_lookup`/`range_index_lookup`/`join`/
  `optional_join`/`union`/`not_exists`/`filter`), followed by the
  post-execution pipeline's own operations
  (`project`/`distinct`/`sort`/`offset`/`limit`) -- independent of any
  Irmin/Pack filesystem detail. `Query_engine.explain`'s existing prose
  remains available in parallel as `planText`, and
  `normalized_core_query_json` renders the lowered query's patterns and
  comparisons as strings for the explain response's
  `normalizedCoreQuery` field.
- `lib/core_query.ml` -- `Core_query.apply` runs the post-execution
  pipeline over a raw `Query_engine.result`: order by full binding
  (`Value.order_compare`, falling back to canonical-string comparison
  for unordered types so `order by` always produces *some* deterministic
  order; a variable left unbound by an unmatched `optional` branch
  always sorts last, for both `ascending` and `descending`), project to
  the requested variables, `distinct`-dedupe on the projected tuple (via
  `Value.equal`, across the whole result set, not just adjacent rows,
  treating two `null`s in the same position as equal), then
  offset/limit.
- `lib/controller.ml`'s `run_query` is the single dispatch point for
  both languages and all three actions (`execute`/`validate`/`explain`),
  used identically by `Api.ml` (`POST /query`) and `Cli_repl.ml` (the
  REPL's query commands) -- neither surface re-implements any part of
  this pipeline, and both build the query environment via the same
  `Query_environment.load_or_build`. `run_query`'s result type
  distinguishes *query-invalid* (`Invalid` -- a `{"valid": false,
  "errors": [...], "language", "languageVersion",
  "environmentFingerprint"}` envelope, for both languages and all three
  actions) from a genuine *request/runtime* `Failure { code; message }`
  (malformed request, timeout, internal error, or a bad
  `language`/`action` parameter) -- `Api.ml` renders the latter as
  `{"error": {"code": ..., "message": ...}}`, never a bare string.
  `Success` responses for `action: "execute"` (both languages) also
  carry `language`/`languageVersion`/`environmentFingerprint` (via
  `Controller.with_environment_fields`), matching the fields already
  present on `validate`/`explain`'s envelope -- so a client can learn
  the dataset's schema fingerprint from any query response, not just
  `/predicates` or the validate/explain actions.

## 7. Schema inference

No user-authored schema is required or supported. `lib/manifest.ml`
computes, purely from the compiled facts for one predicate (during
`Pack_backend.write_predicate_batch`, invoked by `beingdb compile`):

- arity and total fact count;
- per argument position, one entry per **observed type** (mixed-type
  positions naturally produce more than one entry), each with: count,
  distinct-value count (via a canonical-string hash set), and (for
  ordered types) min/max canonical values.

The manifest is stored as JSON at `/meta/<predicate>` and is used both
for predicate introspection (`GET /predicates`) and, at query time, to
decide which type branches a range scan must additionally consider (see
["Range lookup"](#33-range-lookup-and-its-documented-limitation)) so
that genuine type mismatches within an ordered family are detected
rather than silently dropped.

Compile-time warnings are emitted (to stderr, non-fatal) for mixed
argument types at a position. Inconsistent arity within one predicate
file is a fatal compile error, since arity is fixed per predicate.

## 8. Known limitations

- Range scans are correct but not asymptotically optimal: they enumerate
  every distinct index key in the relevant type branch(es) rather than
  performing a true sorted binary search (see
  [3.3](#33-range-lookup-and-its-documented-limitation)).
- Decimal values are stored as an exact `int64` coefficient plus a scale;
  a single decimal literal is limited to roughly 18-19 significant
  digits (`Decimal.of_string` rejects anything larger). The sortable
  index key additionally rescales to a fixed 18 fractional digits
  (`Decimal.sortable_scale`), which can lose precision *in the index key
  only* for values with more than 18 fractional digits; equality and
  ordering comparisons (`Decimal.compare`, `Value.equal`,
  `Value.order_compare`) are always exact regardless.
- No null or list literals, no uncertain dates or date intervals, no
  aggregation, arithmetic or negation.
- Ordering is undefined (raises an error) between two atoms, two
  strings, two booleans, or two URIs; only equality is supported for
  those types.
- URI and BCP 47 language-tag validation are syntactic approximations,
  not full RFC 3986 / BCP 47 implementations.
- No user-authored schema is supported; types are always inferred from
  the compiled facts.
