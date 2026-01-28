# Getting Started with BeingDB

This guide walks you through setting up BeingDB and running your first queries.

## Prerequisites

- **OCaml 5.1+** and **opam** package manager
- **Git** for facts version control
- **Docker** (optional, for production deployment)

See [Installation Guide](installation.md) for detailed setup instructions.

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

**Complete example repository:** [beingdb-sample-facts](https://github.com/jptmoore/beingdb-sample-facts)

## Quick Install

**Linux/macOS:**
```bash
git clone https://github.com/jptmoore/beingdb.git
cd beingdb
opam install . --deps-only -y
dune build --release
dune install
```

**Verify installation:**
```bash
beingdb-serve --help
beingdb-compile --help
beingdb-clone --help
```

For other platforms or troubleshooting, see [Installation Guide](installation.md).

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
beingdb-compile: [INFO] BeingDB Compile
beingdb-compile: [INFO] Source: Irmin Git (./git_store)
beingdb-compile: [INFO] Target: Pack (./pack_store)
beingdb-compile: [INFO] Found 10 predicates in Git HEAD
beingdb-compile: [INFO] Compilation complete!
beingdb-compile: [INFO]   Predicates: 10
beingdb-compile: [INFO]   Total facts: 45147
```

The pack store is read-only and immutable, optimized for fast queries.

### 3. Start the Server

Run the query server pointing at your pack store:

```bash
# Default settings (port 8080, max results 1000, max concurrent 20)
beingdb-serve --pack ./pack_store

# Custom settings
beingdb-serve --pack ./pack_store --port 8080 --max-results 5000 --max-concurrent 40
```

**Server options:**
- `--pack` - Path to pack store directory (required)
- `--port` - HTTP port (default: 8080)
- `--max-results` - Maximum results per query (default: 1000)
- `--max-concurrent` - Maximum concurrent queries (default: 20, prevents file descriptor exhaustion)

Server starts with:
```
beingdb-serve: [INFO] BeingDB Server
beingdb-serve: [INFO] Pack store: ./pack_store
beingdb-serve: [INFO] Starting API server on port 8080
beingdb-serve: [INFO] Max results per query: 1000
beingdb-serve: [INFO] Max concurrent queries: 20
17.01.26 12:00:00.000                Running at http://localhost:8080
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
    {"name": "artist", "arity": 1},
    {"name": "work", "arity": 1}
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
    ["tina_keane", "she"],
    ["tina_keane", "faded_wallpaper"],
    ["tina_keane", "shadow_of_a_journey"]
  ],
  "count": 3
}
```

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

For zero-downtime production updates, see [Deployment Guide](deployment.md).

## Development Tips

**Test queries locally:**
Use a REST client like [httpie](https://httpie.io/):
```bash
http POST :8080/query query='created(Artist, Work)' limit=5
```

**Enable debug logging:**
BeingDB logs to stdout. Redirect to a file:
```bash
beingdb-serve --pack ./pack_store > server.log 2>&1 &
```

**Validate facts before compiling:**
Check your predicate files for syntax errors:
```bash
# Each fact should end with '.'
# Use consistent arity per predicate
grep -r '^\w' predicates/
```

**Run tests:**
```bash
cd beingdb
dune test
```

## Next Steps

- **[Query Language Guide](query-language.md)** - Learn advanced query patterns
- **[API Reference](api.md)** - Complete HTTP API documentation  
- **[Deployment Guide](deployment.md)** - Production deployment with Docker
- **[Installation Guide](installation.md)** - Platform-specific installation

## Common Issues

**"Pack_error: Invalid_layout"**
- Pack store was compiled with a different Irmin version
- Solution: Recompile pack store with current BeingDB installation

**"Connection refused"**
- Server not running or wrong port
- Check: `curl http://localhost:8080/`

**"Query timeout"**
- Query exceeded 5 second limit
- Solution: Add pagination or make query more selective with constants

**Empty results**
- Check predicates exist: `curl http://localhost:8080/predicates`
- Verify fact format in Git repository
- Check case sensitivity (predicates are lowercase)

For more troubleshooting, see [Deployment Guide](deployment.md#troubleshooting).
