# BeingDB

Modern RAG systems are great at retrieving unstructured text, but they struggle with structured facts. Vector search can tell you which documents are similar, but it can’t reliably answer questions like:
- Who created this artwork?
- Where was this shown?
- Which entities are connected?
- What metadata belongs to this item?

Forcing a graph database into your pipeline is not always the best solution: graph databases, while powerful, are often not simple, reproducible, or easy to maintain.

BeingDB gives you a tiny, predictable, Git‑versioned layer for explicit facts — entities, relationships, metadata, keywords, labels — all expressed as simple Prolog‑style predicates.
The runtime stays deliberately minimal. No schema, no inference, just atoms and strings. Your LLM handles the reasoning; BeingDB just provides the clean, structured substrate it needs.


**This combination is powerful for:**
- Chatbots that need reliable metadata
- Research archives and cultural collections
- Digital humanities projects
- Knowledge‑rich assistants
- Any RAG system that needs structure and semantics

BeingDB is small by design, but it unlocks a capability most RAG systems are missing: **fast, explicit, joinable facts — versioned like code, served like a database.**

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
beingdb-serve --pack /var/beingdb/pack-store --port 8080 &

# Query
curl -X POST http://localhost:8080/query -d '{"query": "created(Artist, Work)"}'
```

**Update workflow:**

```bash
# Pull latest changes from remote Git
beingdb-pull --git /var/beingdb/git-store

# Compile to NEW timestamped snapshot (capture timestamp)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
beingdb-compile --git /var/beingdb/git-store --pack /var/beingdb/snapshots/pack-$TIMESTAMP

# Stop old server
pkill beingdb-serve

# Start new server with updated snapshot
beingdb-serve --pack /var/beingdb/snapshots/pack-$TIMESTAMP --port 8080 &
```

**Zero-downtime deployments:**

For production systems, use blue-green deployment:
1. Compile the new snapshot with a timestamp
2. Start the new server on a different port (e.g., 8081)
3. Update your load balancer/reverse proxy to route traffic to the new port
4. Verify the new server is working correctly
5. Stop the old server (running on port 8080)

This ensures no downtime during updates, and allows instant rollback if issues arise. The timestamped snapshots are preserved on disk, so you can quickly restart an old server with a previous snapshot if needed.

## Configuration

The `beingdb-serve` command accepts a `--max-results` argument to set a hard limit on query result sizes:

```bash
beingdb-serve --pack /var/beingdb/pack-store --port 8080 --max-results 5000
```

This limit (default: 1000) cannot be exceeded, even if a query specifies a higher `limit` value. It prevents out-of-memory errors when querying large datasets.

**Example:**
```bash
# Start server with 5000 result limit
beingdb-serve --pack ./pack-store --port 8080 --max-results 5000

# Query requesting 10,000 results will be capped at 5000
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work)", "limit": 10000}'
# Returns at most 5000 results (min of 10000 and max-results)
```

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

**Local testing:**

```bash
# Import example predicates
beingdb-import --input ./examples --git ./git-store

# Compile to pack
beingdb-compile --git ./git-store --pack ./pack-store

# Start server
beingdb-serve --pack ./pack-store --port 8080

# Query
curl http://localhost:8080/predicates
curl -X POST http://localhost:8080/query -d '{"query": "created(Artist, Work)"}'
```

**Unit tests:**

```bash
dune test
```

Tests individual components (Git backend, Pack backend, parsing)

## License

MIT
