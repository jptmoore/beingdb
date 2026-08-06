# BeingDB Query Language

BeingDB uses a typed, Prolog-style query language for pattern matching,
joins, and comparisons over facts.

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

Built-in safety limits prevent runaway queries:

- **Timeout:** 5 seconds maximum execution time.
- **Intermediate results:** 10,000 row limit during joins.
- **Result limit:** configurable via `MAX_RESULTS` (default 5000).

## What BeingDB does NOT support

- **Negation:** no `NOT` operator.
- **Aggregation:** no `COUNT`, `SUM`, `GROUP BY`.
- **Arithmetic:** no `Y = X + 1`.
- **Recursion:** no transitive closure or path queries.
- **Disjunction:** no OR operator (use separate queries).
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

## Further reading

- [Internals](internals.md) -- typed value model, storage layout, fact
  IDs, index encoding, comparison semantics, and current limitations.
- [API Reference](api.md)
- [Installation Guide](installation.md)

