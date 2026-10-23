# BeingDB API Reference

BeingDB provides a RESTful HTTP API for querying facts from the pack store.

## Base URL

```
http://localhost:8080
```

Configure port via `--port` flag or `PORT` environment variable.

## Endpoints

### Health Check

```
GET /
```

Returns `200 OK` with a JSON body.

**Use case:** Container health checks, uptime monitoring

**Example:**
```bash
curl http://localhost:8080/
```

Response:
```json
{ "status": "OK" }
```

---

### Version

```
GET /version
```

Returns BeingDB version information.

**Response:**
```json
{
  "name": "BeingDB",
  "version": "0.2.0"
}
```

**Example:**
```bash
curl http://localhost:8080/version
```

---

### List Predicates

```
GET /predicates
```

Lists all available predicates in the pack store with their arities.

**Query Parameters:**
- `samples` (optional, integer, max 1000) - Include N sample facts for each predicate
- `detailed` (optional, `true`/`1`) - Return full schema detail instead: per-argument observed types, fact counts, bounded typed examples, any declared roles, semantic types and descriptions, and the query-environment fingerprint (see below); mutually exclusive with `samples`
- `q` (optional, string, only with `detailed`) - Filter to predicates whose name contains this substring (case-insensitive)
- `names` (optional, comma-separated string, only with `detailed`) - Filter to an exact set of predicate names

**Response (without samples):**
```json
{
  "predicates": [
    {"name": "created", "arity": 2},
    {"name": "shown_in", "arity": 2},
    {"name": "held_at", "arity": 2},
    {"name": "keyword", "arity": 1}
  ]
}
```

**Response (with samples):**
```json
{
  "predicates": [
    {
      "name": "created",
      "arity": 2,
      "samples": [
        [{"type": "atom", "value": "tina_keane"}, {"type": "atom", "value": "she"}],
        [{"type": "atom", "value": "tina_keane"}, {"type": "atom", "value": "faded_wallpaper"}]
      ],
      "sample_count": 2
    },
    {
      "name": "birth_year",
      "arity": 2,
      "samples": [
        [{"type": "atom", "value": "tina_keane"}, {"type": "year", "value": "1951"}]
      ],
      "sample_count": 1
    }
  ],
  "samples_per_predicate": 20
}
```

**Examples:**
```bash
# List predicates without samples
curl http://localhost:8080/predicates

# List predicates with 20 sample facts each
curl http://localhost:8080/predicates?samples=20

# Full schema detail, filtered by name substring
curl 'http://localhost:8080/predicates?detailed=true&q=creat'
```

**Response (`detailed=true`):**
```json
{
  "predicates": [
    {
      "name": "created_by",
      "arity": 2,
      "count": 3,
      "description": "Relates a work to the person who created it.",
      "arguments": [
        {"position": 0, "types": ["atom"], "role": "Work", "semanticType": "work"},
        {"position": 1, "types": ["atom"], "role": "Creator", "semanticType": "person"}
      ],
      "examples": [
        [{"type": "atom", "value": "she"}, {"type": "atom", "value": "tina_keane"}]
      ]
    }
  ],
  "environmentFingerprint": "sha256:3a1f...c9",
  "languageVersion": "beingdb-dsl/1"
}
```

| Field | Present | Source |
|---|---|---|
| `name`, `arity`, `count` | always | compiled facts |
| `arguments[].position`, `arguments[].types` | always | observed value types at that position |
| `examples` | always (may be empty) | up to 3 stored facts |
| `description` | only if declared | predicate declaration |
| `arguments[].role` | only if argument roles are declared | predicate declaration |
| `arguments[].semanticType` | only if that argument's semantic type is declared | predicate declaration |

Declarations are optional `%!` comments in the predicate's source file,
compiled into the pack. Description, roles and semantic types are
independent: a predicate may have just a description, just roles, or
any combination (see
[Predicate declarations](query-language.md#predicate-declarations-optional)).
Semantic types are descriptive labels and are not checked against the
facts. Predicates without a declaration return exactly the fields shown
before declarations existed, so existing clients are unaffected.

The fingerprint is deterministic (SHA-256 over sorted predicate names,
arities, observed argument types, any declared roles, semantic types and
descriptions, and the query-language version; formatted as
`"sha256:<lowercase hex digest>"`) and changes whenever any of those
change. Packs without declarations keep the fingerprint they had before
declarations existed. This is useful for invalidating cached prompts
or schema descriptions built from this endpoint. The same fingerprint
is exposed, under the same `environmentFingerprint` key, in REPL
startup and every `POST /query` response (`execute`, `validate`, and
`explain` and `diagnose` alike) -- so a client never has to make a
separate call to this endpoint just to learn it.

**Use cases:** 
- Discovery and autocomplete (without samples)
- Schema exploration and validation (with samples, or `detailed=true` for typed argument signatures)
- Bot/LLM predicate caching with example facts and a cache-invalidation fingerprint

**Performance note:** Using `samples` parameter is optimized for large datasets and prevents file descriptor exhaustion by limiting reads per predicate.

---

### Get All Facts for a Predicate

```
GET /query/:predicate
```

Retrieves all facts for a specific predicate.

**Parameters:**
- `:predicate` (path) - The predicate name

**Response:**
```json
{
  "predicate": "created",
  "facts": [
    [{"type": "atom", "value": "tina_keane"}, {"type": "atom", "value": "she"}],
    [{"type": "atom", "value": "tina_keane"}, {"type": "atom", "value": "faded_wallpaper"}]
  ]
}
```

**Example:**
```bash
curl http://localhost:8080/query/created
```

**Use case:** Full predicate export, ETL, exploration

**Note:** No pagination available for this endpoint. For large predicates, use `POST /query` instead.

---

### Execute Query

```
POST /query
```

Run a `find`/`where` query: pattern matching, joins, typed comparisons,
`optional`/`either`/`or`/`not`, ordering and paging.

**Request Body:**
```json
{
  "query": "find Artist, Work, Exhibition\nwhere\n  created(Artist, Work)\n  shown_in(Work, Exhibition)\nlimit 10"
}
```

**Body Parameters:**
- `query` (string, required) - The `find`/`where` query text. Line breaks are written `\n` in JSON. Paging is part of the text: `limit N` and `offset N` lines at the end of the query.
- `action` (string, optional) - `"execute"` (default), `"validate"` (check without running), `"explain"` (show the access plan without running), or `"diagnose"` (validation plus data-aware diagnostics and proven repairs, without running -- see [Diagnose](#diagnose-dsl))
- `language` (string, optional) - May be omitted; the only accepted value is `"dsl"`. `"core"` is rejected with `unsupported_language`, any other value with `unknown_language`.

Request-level `offset` and `limit` fields are not accepted; a request
that includes either is rejected with `unsupported_parameter` (HTTP
400). Text that is not a `find`/`where` query, such as a bare pattern
`created(A, W)`, fails validation with a `syntax_error`.

See [Query Language](query-language.md#query-syntax) for the full
`find`/`where` syntax, validation error shapes, and REPL equivalents.

**Response:**
```json
{
  "variables": ["Artist", "Work", "Exhibition"],
  "results": [
    {
      "Artist": {"type": "atom", "value": "tina_keane"},
      "Work": {"type": "atom", "value": "she"},
      "Exhibition": {"type": "atom", "value": "rewind_exhibition_1995"}
    }
  ],
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

**Response (one page of a larger result, `limit 2`):**
```json
{
  "variables": ["Artist", "Work"],
  "results": [
    { "Artist": {"type": "atom", "value": "tina_keane"}, "Work": {"type": "atom", "value": "she"} },
    { "Artist": {"type": "atom", "value": "tina_keane"}, "Work": {"type": "atom", "value": "faded_wallpaper"} }
  ],
  "count": 2,
  "total": 156,
  "hasMore": true,
  "truncated": false,
  "warnings": [],
  "language": "dsl",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:3a1f...c9"
}
```

Each value in a result is a typed object, `{"type": ..., "value": ...}`
(see [query-language.md](query-language.md#json-result-format)), or
`null` for a variable left unbound by an unmatched `optional` block.
Exact decimal values are always encoded as JSON strings to avoid
precision loss.

**Response Fields** (in this order):
- `variables` - Array of variable names in `find` order
- `results` - Array of result rows, each an object keyed by variable name
- `count` - Number of rows in this response
- `total` - Number of rows the whole query matches (after `distinct`), independent of the query's `limit`/`offset` and the server's `max_results`
- `hasMore` - `true` if more matching rows exist after this page, whether the query's own `limit` or the server's `max_results` stopped it
- `truncated` - `true` if the server's `max_results` cap, not the query's own `limit`, cut the result; a `results_truncated` entry is then added to `warnings`. Page on with `limit`/`offset` in the query text, or narrow the query.
- `warnings` - Advisory warnings (for example `heterogeneous_position`, `results_truncated`)
- `diagnostics`, `provablyEmpty`, `repair` (only when the first page is empty) - the same data-aware explanation the [`diagnose`](#diagnose-dsl) action gives, so a client learns why there are no rows without a second call. `provablyEmpty: false` with no error diagnostics means BeingDB found no reason in the query itself: the facts are simply not recorded.
- `language` - Always `"dsl"`
- `languageVersion` - The query language version (same value as `/predicates?detailed=true`)
- `environmentFingerprint` - The dataset schema fingerprint (same value as `/predicates?detailed=true`); lets a client cache schema knowledge from ordinary query responses alone, without a separate `/predicates` call. Present on every `POST /query` response body, not just `validate`/`explain`.

**Examples:**

Simple pattern:
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "find Artist, Work\nwhere\n  created(Artist, Work)"}'
```

Join, first page of 10:
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "find Artist, Work, Exhibition\nwhere\n  created(Artist, Work)\n  shown_in(Work, Exhibition)\norder by Work\nlimit 10\noffset 0"}'
```

With constants:
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "find Work\nwhere\n  created(tina_keane, Work)"}'
```

String literals:
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "find Doc\nwhere\n  keyword(Doc, \"neural networks\")"}'
```

Validate without executing:
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"action": "validate", "query": "find X\nwhere\n  artst(X)"}'
```

A query that fails validation (`execute` or `validate`) returns HTTP 400
with the structured error list directly as the body (not wrapped in
`"error"`) -- see [Error response shapes](#error-response-shapes):
```json
{
  "valid": false,
  "errors": [
    {"code": "unknown_predicate", "message": "Unknown predicate 'artst'; did you mean: artist?", "line": 2, "column": 3, "predicate": "artst", "suggestions": ["artist"]}
  ],
  "warnings": [],
  "language": "dsl",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:3a1f...c9"
}
```

### Diagnose (DSL)

`"action": "diagnose"` checks a DSL query against the data without running
it, and reports only what BeingDB can establish exactly. It is meant for
clients that generate queries (for example a language model behind MCP or
in the browser), so they can fix cheap, provable mistakes before spending
another expensive generation. The response is always HTTP 200: validation
fields exactly as `validate` reports them, plus `diagnostics`,
`provablyEmpty` and, when BeingDB can prove a correction, `repair`.

```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"language": "dsl", "action": "diagnose", "query": "find Work\nwhere\n  created_by(david_critchley, Work)"}'
```

```json
{
  "valid": true,
  "errors": [],
  "warnings": [],
  "diagnostics": [
    {
      "code": "constant_not_at_position",
      "severity": "error",
      "message": "No created_by fact has 'david_critchley' as argument 0. 'david_critchley' occurs in created_by only at argument 1.",
      "line": 3, "predicate": "created_by", "argumentPosition": 0,
      "value": {"type": "atom", "value": "david_critchley"},
      "scope": "positive",
      "evidence": {"declaredRole": "Work", "occursAtPositions": [1], "occursIn": [{"predicate": "affiliated_with", "argumentPosition": 0}], "occursInCount": 16},
      "repair": {"kind": "swap_arguments", "predicate": "created_by", "line": 3, "positions": [0, 1]}
    },
    {
      "code": "role_name_mismatch",
      "severity": "warning",
      "message": "Work is argument 1 of created_by, whose declared role is Artist; Work is the role of argument 0.",
      "line": 3, "predicate": "created_by", "argumentPosition": 1, "variable": "Work", "scope": "positive",
      "evidence": {"declaredRole": "Artist", "matchesRoleAt": 0, "matchesRole": "Work"}
    }
  ],
  "provablyEmpty": true,
  "repair": {
    "query": "find Work\nwhere\n  created_by(Work, david_critchley)",
    "applied": [{"kind": "swap_arguments", "predicate": "created_by", "line": 3, "positions": [0, 1]}]
  },
  "language": "dsl",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:..."
}
```

Diagnostic codes (all deterministic, computed from the facts and the
predicate declarations):

| Code | Meaning |
|---|---|
| `unknown_constant` | An atom that occurs in no fact of any predicate (`evidence.suggestions`: likely corrections, see below) |
| `constant_not_at_position` | A literal that occurs in no fact of this predicate at this argument (`evidence.occursAtPositions`: where it does occur in this predicate; `occursIn`: other predicates; `suggestions`: likely corrections, see below) |
| `disjoint_join` | A variable joining two positive patterns whose arguments share no value |
| `contradictory_negation` | A `not` block that only repeats clauses that must already hold |
| `singleton_variable` | A named variable used once and not in `find`/`order by`: it matches anything, like `_` |
| `role_name_mismatch` | A variable named after the declared role of a different argument of the same predicate |
| `unsatisfiable_comparison` | A top-level comparison of a variable with literals (`<`, `>=`, `between`, ...) that no value at the variable's argument satisfies, e.g. `Y > @2090` on years from 1968 to 2004 (`evidence.observedRange`: the smallest and largest comparable values there). Checked by running that pattern and the comparison through the query engine, so it always agrees with execution |

`severity: "error"` means the query as written provably returns no rows
(`provablyEmpty` is then `true`); a provably empty clause inside
`optional`/`either`/`not` is a `"warning"`, as is everything that does not
prove emptiness. Diagnostics never change `valid`.

When an atom or string literal occurs nowhere in its predicate, its
`unknown_constant`/`constant_not_at_position` diagnostic also carries
`evidence.suggestions`: up to five values of the same type that do occur
at that argument, ranked as likely corrections (edit distance, or shared
words making up at least half of both values' words, ignoring case,
spaces, hyphens and underscores) and written as
DSL literals, and the message ends with `Did you mean <best>?`. For
example, `created_by(Work, david_critchly)` gives
`"suggestions": ["david_critchley"]`. Suggestions are
hints, not repairs: BeingDB cannot prove which value was meant, so the
client chooses.

A `repair` is offered only when BeingDB can prove it:

- `swap_arguments`: a positive pattern has a literal that matches no fact
  at its position, and exactly one swap of two arguments makes every
  literal of the pattern match.
- `replace_variable`: a positive singleton variable whose name in
  snake_case (`OvalHouse` -> `oval_house`) is an atom that occurs at
  exactly that argument.

`repair.query` is the original text with only the repaired clauses'
lines rewritten; it is returned only if it parses back to exactly the
repaired query. Run it (or `diagnose` it again) like any other query.

---

## Error response shapes

BeingDB distinguishes two error families, never mixing a string and an
object under the same `"error"` key:

**Query-invalid** -- the request itself was fine, but the query is
invalid (syntax error, unknown predicate, arity/type mismatch,
disconnected query, unsafe negation, unbound projection/ordering
variable, ...). Returned by `POST /query` for `action: "validate"`, for
`action: "explain"` when lowering fails, and for `action: "execute"`
when the query fails validation. Always:

```json
{
  "valid": false,
  "errors": [ { "code": "...", "message": "..." } ],
  "warnings": [],
  "language": "dsl",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:..."
}
```

See [Query Language](query-language.md#validation) for the full list of
error codes.

**Request/runtime failure** -- malformed JSON, a missing required field,
a query timeout, an internal error, an unsupported or unrecognized
`language`/`action` value, or request-level `offset`/`limit` fields.
Unrelated to whether the query text is valid. Always:

```json
{ "error": { "code": "malformed_request", "message": "The request body is not valid JSON." } }
```

`code` is one of: `malformed_request`, `invalid_request` (the simpler
endpoints that don't yet carry a specific code), `timeout`,
`internal_error`, `execution_error`, `unsupported_language`,
`unknown_language`, `unknown_action`, `unsupported_parameter`,
`query_too_long` (HTTP 413), `server_busy` (HTTP 429).
See [Safety limits](#safety-limits) for the last two.

### Common Errors

**400 Bad Request - Invalid JSON body**
```json
{ "error": { "code": "malformed_request", "message": "The request body is not valid JSON." } }
```

**400 Bad Request - Missing Query Field**
```json
{ "error": { "code": "malformed_request", "message": "Missing 'query' field" } }
```

**400 Bad Request - Core query language**
```json
{ "error": { "code": "unsupported_language", "message": "The core query language is no longer accepted; send a find/where query instead (omit 'language' or set it to \"dsl\"), e.g. \"find A, W\\nwhere\\n  created(A, W)\"." } }
```

**400 Bad Request - Request-level offset/limit**
```json
{ "error": { "code": "unsupported_parameter", "message": "Request-level 'offset' and 'limit' are not supported; put 'limit N' and 'offset N' at the end of the query text." } }
```

**400 Bad Request - Query Timeout**
```json
{ "error": { "code": "timeout", "message": "Query timeout after 5 seconds - query too expensive. Try limiting predicates or adding more specific constraints." } }
```

**400 Bad Request - Disconnected query (query-invalid, not a runtime error)**
```json
{
  "valid": false,
  "errors": [
    {
      "code": "disconnected_query",
      "message": "The query contains disconnected pattern groups and would produce a Cartesian product.",
      "groups": [ ["person(Person)"], ["organisation(Organisation)"] ]
    }
  ],
  "warnings": [],
  "language": "dsl",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:..."
}
```

**400 Bad Request - Invalid Predicate Name (GET /predicates, GET /query/:predicate)**
```json
{ "error": { "code": "invalid_request", "message": "Invalid predicate name 'Work|Person'. Predicate names must contain only lowercase letters, numbers, and underscores." } }
```

**413 Payload Too Large - Query Too Long**
```json
{ "error": { "code": "query_too_long", "message": "Query is too long: 25000 bytes (maximum 20000). Try splitting it into smaller queries." } }
```

**429 Too Many Requests - Server Busy**
```json
{ "error": { "code": "server_busy", "message": "Too many concurrent queries; please retry shortly." } }
```

---

## Safety limits

`beingdb-serve` enforces sensible defaults to guard against expensive or
malicious queries, overridable via an optional `--config <file.json>`
(missing fields fall back to the defaults below):

| Field | Default | Effect |
|---|---|---|
| `max_results` | 1000 | Hard cap on results returned per query |
| `query_timeout` | 5.0 | Seconds before an executing query is aborted (`timeout`) |
| `max_intermediate_results` | 10000 | Cap on intermediate join rows before aborting |
| `max_query_length` | 20000 | Cap, in bytes, on a raw query string, rejected before parsing (`query_too_long`, HTTP 413) |
| `max_concurrent_queries` | 20 | Cap on simultaneously in-flight `POST /query` requests; further requests get `server_busy` (HTTP 429) until one finishes |

```bash
beingdb-serve --pack ./pack_store --config ./beingdb.config.json
```

The `--max-results` CLI flag, if given, overrides the config file's
`max_results`. These limits guard a single BeingDB process; per-client
rate limiting still belongs in front of BeingDB, e.g. a reverse proxy
(nginx, Caddy) -- the example nginx config in the repository provides a
10 requests/second limit.

---

## CORS

BeingDB does not set CORS headers by default. Use a reverse proxy to add CORS headers if needed for browser-based clients.

---

## Authentication

BeingDB has no built-in authentication. Deploy behind:
- Nginx with HTTP Basic Auth
- OAuth2 Proxy
- API Gateway with auth layer

For read-only deployments, consider network isolation (VPC, firewall rules).

---

## Performance

**Single predicate queries:** Sub-millisecond for most datasets

**Joins:** The full projected result is computed in memory, then the
requested page is returned, so `total` is always exact
- Fast for small result sets (< 1000 rows)
- `limit`/`offset` reduce the response size, not the work; add constants or comparisons to narrow large joins
- Intermediate join rows are capped by `max_intermediate_results` (see [Safety limits](#safety-limits))

**Query optimization:** Automatic pattern reordering by selectivity

**Caching:** Pack store is immutable; consider HTTP cache headers via reverse proxy

---

## Client Libraries

No official client libraries yet. Use standard HTTP libraries:

**JavaScript/TypeScript:**
```typescript
const response = await fetch('http://localhost:8080/query', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    query: 'find Artist, Work\nwhere\n  created(Artist, Work)\nlimit 10\noffset 0'
  })
});
const data = await response.json();
```

**Python:**
```python
import requests

response = requests.post('http://localhost:8080/query', json={
    'query': 'find Artist, Work\nwhere\n  created(Artist, Work)\nlimit 10\noffset 0'
})
data = response.json()
```

**curl:**
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "find Artist, Work\nwhere\n  created(Artist, Work)\nlimit 10\noffset 0"}'
```

---

## Further Reading

- [Query Language](query-language.md)
- [Installation Guide](installation.md)
