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

Returns `200 OK` with plain text body.

**Use case:** Container health checks, uptime monitoring

**Example:**
```bash
curl http://localhost:8080/
```

Response:
```
OK
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
  "version": "0.1.0"
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
- `detailed` (optional, `true`/`1`) - Return full schema detail instead: per-argument observed types, fact counts, bounded typed examples, and the query-environment fingerprint (see below); mutually exclusive with `samples`
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
      "name": "created",
      "arity": 2,
      "count": 3,
      "arguments": [
        {"position": 0, "types": ["atom"]},
        {"position": 1, "types": ["atom"]}
      ],
      "examples": [
        [{"type": "atom", "value": "tina_keane"}, {"type": "atom", "value": "she"}]
      ]
    }
  ],
  "environmentFingerprint": "sha256:3a1f...c9",
  "languageVersion": "beingdb-dsl/1"
}
```

The fingerprint is deterministic (SHA-256 over sorted predicate names,
arities, observed argument types, and the expressive query-language
version; formatted as `"sha256:<lowercase hex digest>"`) and changes
whenever any of those change -- useful for invalidating cached prompts
or schema descriptions built from this endpoint. The same fingerprint
is exposed, under the same `environmentFingerprint` key, in REPL
startup and every `validate`/`explain` response.

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

Execute pattern matching queries with joins and pagination, in either
the core or the expressive query language.

**Request Body:**
```json
{
  "query": "created(Artist, Work), shown_in(Work, Exhibition)",
  "offset": 0,
  "limit": 10
}
```

**Body Parameters:**
- `query` (string, required) - Query text: core language pattern(s), or (with `"language": "dsl"`) an expressive `find`/`where` query
- `offset` (integer, optional) - Start position for pagination (default: 0); core language only
- `limit` (integer, optional) - Maximum results to return (default: server's `max_results`, see [Safety limits](#safety-limits)); core language only -- for the expressive language, use `limit`/`offset` inside the query text itself
- `language` (string, optional) - `"core"` (default) or `"dsl"`
- `action` (string, optional) - `"execute"` (default), `"validate"` (check without running), or `"explain"` (show the access plan without running)

See [Query Language](query-language.md#expressive-query-language) for
the full `find`/`where` syntax, validation error shapes, and REPL
equivalents.

**Response (without pagination):**
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
  "total": 1
}
```

**Response (with pagination):**
```json
{
  "variables": ["Artist", "Work"],
  "results": [
    { "Artist": {"type": "atom", "value": "tina_keane"}, "Work": {"type": "atom", "value": "she"} },
    { "Artist": {"type": "atom", "value": "tina_keane"}, "Work": {"type": "atom", "value": "faded_wallpaper"} }
  ],
  "count": 2,
  "total": 156,
  "offset": 0,
  "limit": 10
}
```

Each value in a result is a typed object, `{"type": ..., "value": ...}`
(see [query-language.md](query-language.md#json-result-format)). Exact
decimal values are always encoded as JSON strings to avoid precision
loss.

**Response Fields:**
- `variables` - Array of variable names in order
- `results` - Array of result tuples (each tuple matches variable order)
- `count` - Number of results in this response
- `total` - Total results across all pages (only with pagination)
- `offset` - Echo of request offset (only with pagination)
- `limit` - Echo of request limit (only with pagination)

**Examples:**

Simple pattern:
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "created(Artist, Work)"}'
```

Join with pagination:
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition)", "offset": 0, "limit": 10}'
```

With constants:
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "created(tina_keane, Work)"}'
```

String literals:
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "keyword(Doc, \"neural networks\")"}'
```

Expressive query language:
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"language": "dsl", "query": "find Artist, Work\nwhere\n  created(Artist, Work)\nlimit 10"}'
```

Validate without executing:
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"language": "dsl", "action": "validate", "query": "find X\nwhere\n  artst(X)"}'
```

A query that fails validation (`execute` or `validate`, either language)
returns HTTP 400 with the structured error list directly as the body
(not wrapped in `"error"`) -- see [Error response shapes](#error-response-shapes):
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

---

## Error response shapes

BeingDB distinguishes two error families, never mixing a string and an
object under the same `"error"` key:

**Query-invalid** -- the request itself was fine, but the query is
invalid (syntax error, unknown predicate, arity/type mismatch,
disconnected query, unsafe negation, unbound projection/ordering
variable, ...). Returned by `POST /query` for `action: "validate"`, for
`action: "explain"` when lowering fails, and for `action: "execute"` 
(either language) when the query fails validation. Always:

```json
{
  "valid": false,
  "errors": [ { "code": "...", "message": "..." } ],
  "warnings": [],
  "language": "core",
  "languageVersion": "beingdb-dsl/1",
  "environmentFingerprint": "sha256:..."
}
```

See [Query Language](query-language.md#validation) for the full list of
error codes.

**Request/runtime failure** -- malformed JSON, a missing required field,
a query timeout, an internal error, or an unrecognized `language`/
`action` value. Unrelated to whether the query text is valid. Always:

```json
{ "error": { "code": "malformed_request", "message": "The request body is not valid JSON." } }
```

`code` is one of: `malformed_request`, `invalid_request` (the simpler
endpoints that don't yet carry a specific code), `timeout`,
`internal_error`, `execution_error`, `unknown_language`,
`unknown_action`, `query_too_long` (HTTP 413), `server_busy` (HTTP 429).
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
  "language": "core",
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

**Joins without pagination:** Full materialization in memory
- Fast for small result sets (< 1000 rows)
- Can hit memory limits on large joins

**Joins with pagination:** Streaming execution
- Two-pass: count total, then stream to page
- Constant memory usage
- Recommended for all production joins

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
    query: 'created(Artist, Work)', 
    offset: 0, 
    limit: 10 
  })
});
const data = await response.json();
```

**Python:**
```python
import requests

response = requests.post('http://localhost:8080/query', json={
    'query': 'created(Artist, Work)',
    'offset': 0,
    'limit': 10
})
data = response.json()
```

**curl:**
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "created(Artist, Work)", "offset": 0, "limit": 10}'
```

---

## Further Reading

- [Query Language](query-language.md)
- [Installation Guide](installation.md)
