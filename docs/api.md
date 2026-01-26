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

**Response:**
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

**Example:**
```bash
curl http://localhost:8080/predicates
```

**Use case:** Discovery, autocomplete, validation

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
    ["tina_keane", "she"],
    ["tina_keane", "faded_wallpaper"],
    ["tina_keane", "shadow_of_a_journey"]
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

Execute pattern matching queries with joins and pagination.

**Request Body:**
```json
{
  "query": "created(Artist, Work), shown_in(Work, Exhibition)",
  "offset": 0,
  "limit": 10
}
```

**Body Parameters:**
- `query` (string, required) - Query pattern(s) in Prolog-style syntax
- `offset` (integer, optional) - Start position for pagination (default: 0)
- `limit` (integer, optional) - Maximum results to return (default: server's `MAX_RESULTS`)

**Response (without pagination):**
```json
{
  "variables": ["Artist", "Work", "Exhibition"],
  "results": [
    ["tina_keane", "she", "rewind_exhibition_1995"],
    ["tina_keane", "faded_wallpaper", "ica_london_2010"]
  ],
  "count": 2
}
```

**Response (with pagination):**
```json
{
  "variables": ["Artist", "Work"],
  "results": [
    ["tina_keane", "she"],
    ["tina_keane", "faded_wallpaper"]
  ],
  "count": 2,
  "total": 156,
  "offset": 0,
  "limit": 10
}
```

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
- [Deployment Guide](deployment.md)
- [Installation Guide](installation.md)
