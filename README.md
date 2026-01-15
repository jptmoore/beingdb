# BeingDB

**Facts versioned like code, queried like a database.**

Modern RAG systems retrieve unstructured text well, but struggle with structured facts. Vector search finds similar documents, but can't reliably answer:
- Who created this artwork?
- Where was this shown?
- Which entities are connected through relationships?

BeingDB solves this by treating facts like source code: **store them in Git, query them from an optimized runtime**.

## Why Git for Facts?

**Traditional knowledge bases require:**
- SQL databases: Manual migrations, DBA gatekeeping, no native versioning
- Graph databases: CSV imports, no collaboration workflow
- JSON files: No review process or provenance

**BeingDB's Git workflow gives you:**
- **Pull requests for knowledge** - Domain experts propose facts, get peer review
- **Version history** - Full audit trail of who added what when
- **Branching & testing** - Test new facts in branches before production merge
- **CI/CD integration** - Validate facts in PR checks, auto-deploy on merge
- **Team collaboration** - Multiple curators using familiar Git tools
- **Instant rollback** - Revert to any known-good fact set

Your knowledge base evolves like a codebase. Subject matter experts who already use Git for documentation can contribute facts using the same workflow.

## Simple Query Language

Facts are Prolog-style predicates—one fact per file:
```prolog
created(tina_keane, she).
shown_in(she, rewind_exhibition_1995).
held_at(rewind_exhibition_1995, ica_london).
```

Query with pattern matching and joins:
```
created(Artist, Work), shown_in(Work, Exhibition)
```

No schema, no complex rules. Your LLM handles reasoning; BeingDB provides the reliable, joinable facts.

**Perfect for:**
- RAG chatbots needing structured metadata alongside vectors
- Research archives with multiple curators
- Digital humanities projects requiring provenance
- Knowledge bases that evolve through team collaboration
- Any system where facts should be reviewed and versioned like code

BeingDB is small by design, but unlocks something most RAG systems lack: **collaborative, versioned, queryable facts.**

## Installation

**Linux (Ubuntu/Debian):**

```bash
# Install OCaml and opam
sudo apt-get update
sudo apt-get install -y opam libgmp-dev libev-dev libssl-dev pkg-config

# Initialize opam (if not already done)
opam init -y
eval $(opam env)

# Install OCaml 5.1 (or later)
opam switch create 5.1.0
eval $(opam env)

# Clone and build BeingDB
git clone https://github.com/jptmoore/beingdb.git
cd beingdb
opam install . --deps-only -y
dune build --release

# Install binaries to ~/.local/bin or /usr/local/bin
dune install
```

**macOS:**

```bash
# Install dependencies via Homebrew
brew install opam gmp libev openssl pkg-config

# Then follow the same opam/dune steps as Linux above
```

After installation, the following binaries will be available:
- `beingdb-clone` - Clone a Git repository of facts
- `beingdb-pull` - Pull updates from remote Git
- `beingdb-import` - Import local predicate files (dev/testing)
- `beingdb-compile` - Compile Git store to optimized Pack format
- `beingdb-serve` - Start HTTP query server

## Quick Start

**Production workflow** (Git repository with predicates):

```bash
# One-time: Clone facts from remote Git repository
beingdb-clone https://github.com/org/facts.git --git /var/beingdb/git-store

# Compile to pack snapshot
beingdb-compile --git /var/beingdb/git-store --pack /var/beingdb/pack-store

# Start server
beingdb-serve --pack /var/beingdb/pack-store --port 8080 --max-results 5000 &

# Query
curl -X POST http://localhost:8080/query -d '{"query": "created(Artist, Work)"}'
```

**Update workflow:**

```bash
# Pull latest changes from remote Git repository
beingdb-pull https://github.com/org/facts.git --git /var/beingdb/git-store

# Compile to NEW timestamped snapshot (capture timestamp)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
beingdb-compile --git /var/beingdb/git-store --pack /var/beingdb/snapshots/pack-$TIMESTAMP

# Stop old server
pkill beingdb-serve

# Start new server with updated snapshot
beingdb-serve --pack /var/beingdb/snapshots/pack-$TIMESTAMP --port 8080 --max-results 5000 &
```

**Zero-downtime deployments:**

For production systems, use blue-green deployment:
1. Compile the new snapshot with a timestamp
2. Start the new server on a different port (e.g., 8081)
3. Update your load balancer/reverse proxy to route traffic to the new port
4. Verify the new server is working correctly
5. Stop the old server (running on port 8080)

This ensures no downtime during updates, and allows instant rollback if issues arise. The timestamped snapshots are preserved on disk, so you can quickly restart an old server with a previous snapshot if needed.

## Query Language

**Facts** (examples/sample_predicates.pl):

```prolog
created(tina_keane, she).
shown_in(she, rewind_exhibition_1995).
held_at(rewind_exhibition_1995, ica_london).
keyword(doc_456, "neural networks").
```

**Terms:**

- `Work`, `Artist` - Variables (uppercase)
- `tina_keane`, `1979` - Atoms (lowercase)
- `"neural networks"` - Strings (quoted)
- `_` - Wildcard

**Query Examples:**

```bash
# Pattern matching
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(tina_keane, Work)"}'

# With pagination
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work)", "offset": 0, "limit": 10}'

# Joins
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition), held_at(Exhibition, Venue)"}'

# Joins with pagination
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition)", "offset": 5, "limit": 3}'

# Strings
curl -X POST http://localhost:8080/query \
  -d '{"query": "keyword(Doc, \"neural networks\")"}'
```

## API

- `GET /predicates` - List predicates
- `GET /query/:predicate` - Get all facts for predicate
- `POST /query` - Execute query with joins
  - Body: `{"query": "...", "offset": 0, "limit": 10}` (offset/limit optional)

Response: `{"variables": [...], "results": [...], "count": N, "total": M, "offset": 0, "limit": 10}`

## Development

**Unit tests:**

```bash
dune test
```

Tests individual components (Git backend, Pack backend, parsing)

## License

MIT
