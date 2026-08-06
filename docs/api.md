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
  "fingerprint": "md5:3aa13057aa16d1340adbd77e02d266ab",
  "language_version": "beingdb-dsl/1"
}
```

The fingerprint is deterministic (MD5 over sorted predicate names,
arities, observed argument types, and the expressive query-language
version) and changes whenever any of those change -- useful for
invalidating cached prompts or schema descriptions built from this
endpoint.

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
- `limit` (integer, optional) - Maximum results to return (default: server's `MAX_RESULTS`); core language only -- for the expressive language, use `limit`/`offset` inside the query text itself
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
(not wrapped in `"error"`):
```json
{
  "valid": false,
  "errors": [
    {"code": "unknown_predicate", "message": "Unknown predicate 'artst'; did you mean: artist?", "line": 2, "predicate": "artst", "suggestions": ["artist"]}
  ],
  "warnings": []
}
```

---

## Error Responses

All errors return JSON with an `error` field:

```json
{
  "error": "Error message here"
}
```

### Common Errors

**400 Bad Request - Invalid Query Syntax**
```json
{
  "error": "Parse error: unexpected token at line 1, column 15"
}
```

**400 Bad Request - Invalid Predicate Name**
```json
{
  "error": "Invalid predicate name 'Work|Person'. Predicate names can only contain lowercase letters, digits, and underscores."
}
```

**400 Bad Request - Query Timeout**
```json
{
  "error": "Query timeout: exceeded 5 second limit"
}
```

**400 Bad Request - Too Many Intermediate Results**
```json
{
  "error": "Intermediate result limit exceeded (max: 10000)"
}
```

**400 Bad Request - Missing Query Field**
```json
{
  "error": "Missing 'query' field"
}
```

**400 Bad Request - Invalid JSON**
```json
{
  "error": "Expected JSON object"
}
```

---

## Rate Limiting

Not built into BeingDB directly. Use a reverse proxy (nginx, Caddy) for production rate limiting.

Example nginx config included in repository provides 10 requests/second limit.

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
