# Getting Started with BeingDB

This guide walks you through setting up BeingDB and running your first queries.

**First time?** Install BeingDB following the [Installation Guide](installation.md).

## Repository Structure

Your facts repository must follow this structure:

```
your-facts-repo/
├── predicates/          # Required directory
│   ├── created.pl       # One predicate per file
│   ├── shown_in.pl      # .pl extension recommended
│   ├── held_at.pl
│   └── description.pl
└── README.md            # Optional documentation
```

**Best practices:**
- All predicate files must be under `predicates/` directory
- Use `.pl` extension for syntax highlighting and clarity (automatically stripped by BeingDB)
- One predicate type per file (e.g., all `created(...)` facts in `created.pl`)
- **Each predicate must have consistent arity** - mixing `created(a, b)` and `created(a, b, c)` in the same file will cause compile errors
- File name becomes the predicate name (`created.pl` → `created` predicate)
- Files without `.pl` extension work too (`created` file → `created` predicate)

**Example `predicates/created.pl`:**
```prolog
created(tina_keane, she).
created(tina_keane, faded_wallpaper).
created(tina_keane, shadow_of_a_journey).
```

**Example `predicates/shown_in.pl`:**
```prolog
shown_in(she, rewind_exhibition_1995).
shown_in(faded_wallpaper, ica_london_2010).
```

Types are inferred directly from literal syntax -- no schema file is
needed. See [beingdb-sample-facts](https://github.com/jptmoore/beingdb-sample-facts)
for a worked example covering every literal type (strings,
language-tagged strings, integers, decimals, booleans, years,
year-months, dates, instants, and URIs), and
[query-language.md](query-language.md) for the full typed syntax and
comparison operators.

**Complete example repository:** [beingdb-sample-facts](https://github.com/jptmoore/beingdb-sample-facts)

## Local Development Workflow

### 1. Clone a Facts Repository

Use an existing facts repository or create your own:

```bash
# Clone the sample facts repository
beingdb-clone https://github.com/jptmoore/beingdb-sample-facts.git --git ./git_store

# Or clone your own facts repository
beingdb-clone https://github.com/your-org/your-facts.git --git ./git_store
```

This creates a `git_store/` directory with your facts in Git format.

### 2. Compile to Pack Format

Transform Git facts into an optimized pack store:

```bash
beingdb-compile --git ./git_store --pack ./pack_store
```

Output:
```
BeingDB Compile
Source: Irmin Git (./git_store)
Target: Pack (./pack_store)

Found 10 predicates

✓ created (45 facts)
✓ shown_in (32 facts)
...

Compilation complete!
Predicates: 10
Total facts: 45147
```

The pack store is read-only and immutable, optimized for fast queries.

### 3. Start the Server

Run the query server pointing at your pack store:

```bash
# Default settings (port 8080, max results 1000)
beingdb-serve --pack ./pack_store

# Custom settings
beingdb-serve --pack ./pack_store --port 8080 --max-results 5000
```

**Server options:**
- `--pack` - Path to pack store directory (default: `./pack_store`)
- `--port` - HTTP port (default: 8080)
- `--max-results` - Maximum results per query, a hard limit (default: 1000); overrides the config file's `max_results` if given
- `--config` - Path to a JSON config file with safety limits guarding against expensive/malicious queries (`max_results`, `query_timeout`, `max_intermediate_results`, `max_query_length`, `max_concurrent_queries`); see [API Reference](api.md#safety-limits)

Server starts with:
```
BeingDB Server
Pack store: ./pack_store
Starting API server on port 8080
Max results per query: 1000
Query timeout: 5.0s
Max intermediate results: 10000
Max query length: 20000 bytes
Max concurrent queries: 20
Running at http://localhost:8080
```

### 4. Query Your Facts

**List available predicates:**
```bash
curl http://localhost:8080/predicates
```

Response:
```json
{
  "predicates": [
    {"name": "created", "arity": 2},
    {"name": "shown_in", "arity": 2},
    {"name": "held_at", "arity": 2},
    {"name": "year_created", "arity": 2},
    {"name": "condition_rating", "arity": 2}
  ]
}
```

**Get all facts for a predicate:**
```bash
curl http://localhost:8080/query/created
```

**Pattern matching query:**
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "created(Artist, Work)"}'
```

Response:
```json
{
  "variables": ["Artist", "Work"],
  "results": [
    { "Artist": {"type": "atom", "value": "tina_keane"}, "Work": {"type": "atom", "value": "she"} },
    { "Artist": {"type": "atom", "value": "tina_keane"}, "Work": {"type": "atom", "value": "faded_wallpaper"} },
    { "Artist": {"type": "atom", "value": "tina_keane"}, "Work": {"type": "atom", "value": "shadow_of_a_journey"} }
  ],
  "count": 3,
  "total": 3
}
```

Each value is a typed object (`{"type": ..., "value": ...}`); see
[query-language.md](query-language.md#json-result-format).

**Join query:**
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition)"}'
```

**Paginated query:**
```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{
    "query": "created(Artist, Work)",
    "offset": 0,
    "limit": 10
  }'
```

## Creating Your Own Facts Repository

### 1. Initialize Repository

```bash
mkdir my-facts
cd my-facts
git init
mkdir predicates
```

### 2. Add Facts

Create predicate files in `predicates/`:

**predicates/person.pl:**
```prolog
person(alice).
person(bob).
person(carol).
```

**predicates/knows.pl:**
```prolog
knows(alice, bob).
knows(bob, carol).
knows(carol, alice).
```

**predicates/lives_in.pl:**
```prolog
lives_in(alice, london).
lives_in(bob, paris).
lives_in(carol, berlin).
```

### 3. Commit and Push

```bash
git add predicates/
git commit -m "Initial facts"
git remote add origin https://github.com/your-org/my-facts.git
git push -u origin main
```

### 4. Use in BeingDB

```bash
beingdb-clone https://github.com/your-org/my-facts.git --git ./git_store
beingdb-compile --git ./git_store --pack ./pack_store
beingdb-serve --pack ./pack_store
```

Query:
```bash
curl -X POST http://localhost:8080/query \
  -d '{"query": "person(P), lives_in(P, City)"}'
```

## Update Workflow

When facts change in your Git repository:

```bash
# 1. Pull latest changes
cd git_store && git pull && cd ..

# 2. Recompile pack store
beingdb-compile --git ./git_store --pack ./pack_store_new

# 3. Stop server, swap pack, restart
pkill beingdb-serve
mv pack_store pack_store_old
mv pack_store_new pack_store
beingdb-serve --pack ./pack_store &

# 4. Verify
curl http://localhost:8080/predicates
```

## Interactive REPL

`beingdb repl` (equivalently, the standalone `beingdb-repl`) opens a
compiled Pack store and reads queries from the terminal, one per line,
printing typed JSON results -- useful for exploring a store or trying
out query syntax without an HTTP server:

```bash
beingdb repl --pack ./pack_store
# or: beingdb-repl --pack ./pack_store
```

```
beingdb> created(Artist, Work)
{
  "variables": [ "Artist", "Work" ],
  "results": [
    { "Artist": { "type": "atom", "value": "tina_keane" }, "Work": { "type": "atom", "value": "she" } }
  ],
  "count": 1,
  "total": 1,
  "limit": 1000
}
```

The REPL has three query-language modes, switched with `:core`, `:dsl`,
and `:auto` (the default, which detects the expressive language when a
query starts with `find`). In `:dsl` mode (or when auto-detected as
`dsl`), keep entering lines and finish with a blank line, since the
expressive syntax spans multiple lines:

```
beingdb> :dsl
mode: dsl
beingdb> find Artist, Work
where
  created(Artist, Work)
limit 5

{
  "variables": [ "Artist", "Work" ],
  "results": [
    { "Artist": { "type": "atom", "value": "tina_keane" }, "Work": { "type": "atom", "value": "she" } }
  ],
  "count": 1,
  "warnings": []
}
```

A line starting with `:` is a REPL command rather than a query:

| Command | Effect |
|---|---|
| `:predicates` | List predicates and their arities |
| `:describe <predicate>` | Show a predicate's argument types, fact count, and examples |
| `:environment` | Show predicate count, fingerprint, language version, and current mode |
| `:explain <query>` | Show the chosen query plan without executing it (single-line only) |
| `:validate` | Enter a query (blank line to finish) and validate it without executing |
| `:core` / `:dsl` / `:auto` | Switch the query-language mode |
| `:load <file>` | Load facts (`.pl`, `.pro`, `.facts`) or run each line as a query (any other extension) |
| `:loadfacts <file>` | Force-load a file as facts, written directly into the open Pack store |
| `:loadqueries <file>` | Force-run every non-blank, non-comment line of a file as a query |
| `:limit <n>` | Set the default max rows shown per query for the rest of the session |
| `:help` | List commands |
| `:quit` / `:exit` | Leave the REPL |

`:load`/`:loadfacts` write straight into the open Pack store -- a
REPL-only convenience for quick, local experimentation. This does not
go through the Git-first compile workflow, so anything loaded this way
is not reflected in the source repository and will be lost the next
time the store is recompiled from Git.

See [Query Language](query-language.md#expressive-query-language) for
the full `find`/`where` syntax reference.


