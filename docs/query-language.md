# BeingDB Query Language

BeingDB uses a simple Prolog-style query language for pattern matching and joins over facts.

## Facts Syntax

Facts are predicates with atoms (lowercase), strings (quoted), or numbers:

```prolog
created(tina_keane, she).
shown_in(she, rewind_exhibition_1995).
held_at(rewind_exhibition_1995, ica_london).
keyword(doc_456, "neural networks").
year_created(she, 1979).
```

**Rules:**
- Predicate names: lowercase, alphanumeric + underscore only
- Arguments: atoms, strings, or numbers
- Consistent arity: All facts for a predicate must have the same number of arguments
- One fact per line
- Terminated with `.`

## Query Terms

| Type | Syntax | Example | Description |
|------|--------|---------|-------------|
| **Variable** | Uppercase | `Work`, `Artist`, `X` | Binds to values during matching |
| **Atom** | Lowercase | `tina_keane`, `she` | Exact match constant |
| **String** | Quoted | `"neural networks"` | String literal |
| **Number** | Digits | `1979`, `42` | Numeric constant |
| **Wildcard** | `_` | `_` | Matches anything, not bound |

## Query Patterns

### Single Pattern

Match one predicate with variables:

```bash
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work)"}'
```

Response:
```json
{
  "variables": ["Artist", "Work"],
  "results": [
    ["tina_keane", "she"],
    ["tina_keane", "faded_wallpaper"],
    ["tina_keane", "shadow_of_a_journey"]
  ],
  "count": 3
}
```

### Multiple Patterns (Joins)

Combine patterns with comma-separated joins. Variables appearing in multiple patterns act as join keys:

```bash
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition)"}'
```

**How it works:**
1. First pattern binds `Artist` and `Work`
2. Second pattern joins on `Work` variable
3. Only results where `Work` appears in both facts are returned

Response:
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

### Three-Way Joins

Chain multiple predicates:

```bash
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition), held_at(Exhibition, Venue)"}'
```

Joins on:
- `Work` (links created → shown_in)
- `Exhibition` (links shown_in → held_at)

### Wildcards

Use `_` to match without binding:

```bash
# Get all artists (don't care about which work)
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, _)"}'

# Get all works shown somewhere (don't care where)
curl -X POST http://localhost:8080/query \
  -d '{"query": "shown_in(Work, _)"}'
```

### Constants in Queries

Fix specific values to filter results:

```bash
# All works by tina_keane
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(tina_keane, Work)"}'

# Where was 'she' exhibited?
curl -X POST http://localhost:8080/query \
  -d '{"query": "shown_in(she, Exhibition)"}'

# Which artists showed work at rewind_exhibition_1995?
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work), shown_in(Work, rewind_exhibition_1995)"}'
```

### String Literals

Use double quotes for string constants:

```bash
curl -X POST http://localhost:8080/query \
  -d '{"query": "keyword(Doc, \"neural networks\")"}'
```

Escape quotes in JSON with `\"`.

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
- First pass: Stream through all results to count total
- Second pass: Stream to offset and return page
- Memory-efficient for large result sets

## Query Optimization

BeingDB automatically optimizes query execution:

1. **Automatic reordering** - Patterns with more constants execute first (higher selectivity)
2. **Early cutoff** - Stops processing once limit is reached (with pagination)
3. **Streaming joins** - Constant memory for multi-pattern queries with pagination

Example:
```
mentioned_with(W, tate_britain), work(W)
```

Automatically reordered to:
```
mentioned_with(W, tate_britain), work(W)  # mentioned_with executes first (has constant)
```

No manual optimization needed!

## Query Protections

Built-in safety limits prevent runaway queries:

- **Timeout:** 5 seconds maximum execution time
- **Intermediate results:** 10,000 row limit during joins
- **Result limit:** Configurable via `MAX_RESULTS` (default 5000)

If a query exceeds these limits, you'll get a clear error message explaining which limit was hit.

## What BeingDB Does NOT Support

- **Negation:** No `NOT` operator (e.g., `not(created(X, Y))`)
- **Aggregation:** No `COUNT`, `SUM`, `GROUP BY`
- **Arithmetic:** No `X > 5` or `Y = X + 1`
- **Recursion:** No transitive closure or path queries
- **Disjunction:** No OR operator (must be separate queries)
- **Functions:** No computed values or transformations

**Why?** BeingDB provides simple, reliable fact retrieval. Your LLM or application layer handles reasoning, aggregation, and complex logic.

## Best Practices

1. **Order doesn't matter** - BeingDB optimizes automatically
2. **Use constants** - `created(tina_keane, W)` is faster than `created(A, W)`
3. **Paginate joins** - Always use `offset`/`limit` with multi-pattern queries
4. **Keep predicates simple** - One relationship type per predicate
5. **Consistent arity** - All facts for a predicate must have the same number of arguments

## Further Reading

- [API Reference](api.md)
- [Deployment Guide](deployment.md)
- [Installation Guide](installation.md)
