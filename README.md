# BeingDB

Modern RAG systems are great at retrieving unstructured text, but they struggle with structured facts. Vector search can tell you which documents are similar, but it can’t reliably answer questions like:
- Who created this artwork?
- Where was this shown?
- Which entities are connected?
- What metadata belongs to this item?

Forcing a graph database into your pipeline is not always the best solution: graph databases, while powerful, are often not simple, reproducible, or easy to maintain.
**BeingDB fills this gap.**

It gives you a tiny, predictable, Git‑versioned layer for explicit facts — entities, relationships, metadata, keywords, labels — all expressed as simple Prolog‑style predicates.
The runtime stays deliberately minimal. No schema, no inference, just atoms and strings. Your LLM handles the reasoning; BeingDB just provides the clean, structured substrate it needs.

**The result:**  
A retrieval stack where vector search finds the right documents, and BeingDB provides the factual backbone the LLM can trust.

**This combination is powerful for:**
- Chatbots that need reliable metadata
- Research archives and cultural collections
- Digital humanities projects
- Knowledge‑rich assistants
- Any RAG system that needs structure and semantics

BeingDB is small by design, but it unlocks a capability most RAG systems are missing: **fast, explicit, joinable facts — versioned like code, served like a database.**

## Quick Start

**Production workflow** (Git repository with predicates):

```bash
# Build the image
docker compose build

# One-time: Clone facts from remote Git repository
docker compose run --rm beingdb beingdb-clone https://github.com/org/facts.git --git /data/git-store

# Compile to pack snapshot
docker compose run --rm beingdb beingdb-compile --git /data/git-store --pack /data/pack-store

# Start server
docker compose run --rm -d -p 8080:8080 beingdb beingdb-serve --pack /data/pack-store --port 8080

# Query
curl -X POST http://localhost:8080/query -d '{"query": "created(Artist, Work)"}'
```

**Update workflow:**

```bash
# Pull latest changes from remote Git
docker compose run --rm beingdb beingdb-pull --git /data/git-store

# Compile to NEW timestamped snapshot (capture timestamp)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
docker compose run --rm beingdb beingdb-compile --git /data/git-store --pack /data/snapshots/pack-$TIMESTAMP

# Stop old server
docker stop beingdb-server

# Start new server with updated snapshot
docker compose run --rm -d -p 8080:8080 --name beingdb-server \
  beingdb beingdb-serve --pack /data/snapshots/pack-$TIMESTAMP --port 8080
```

**Or for zero-downtime with blue-green:**

```bash
# Compile to new snapshot
docker compose run --rm beingdb beingdb-compile --git /data/git-store --pack /data/snapshots/pack-new

# Start new server on different port
docker compose run --rm -d -p 8081:8080 --name beingdb-green \
  beingdb beingdb-serve --pack /data/snapshots/pack-new --port 8080

# Test it
curl http://localhost:8081/predicates

# Switch load balancer/proxy from 8080 → 8081, then:
docker stop beingdb-server
docker rm beingdb-server
docker rename beingdb-green beingdb-server
```

**Production data safety:**

- `beingdb-serve` - Read-only, never modifies pack store
- `beingdb-compile` - Always creates fresh pack (overwrites target directory)
- `beingdb-pull` - Updates Git store in-place (use Git for versioning)
- ⚠️ Always compile to NEW directories to preserve previous snapshots

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

# Joins
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition), held_at(Exhibition, Venue)"}'

# Strings
curl -X POST http://localhost:8080/query \
  -d '{"query": "keyword(Doc, \"neural networks\")"}'
```

## API

- `GET /predicates` - List predicates
- `GET /query/:predicate` - Get all facts for predicate
- `POST /query` - Execute query with joins

Response: `{"variables": [...], "results": [...], "count": N}`

## Testing

**Integration tests** (Docker, no OCaml required):

```bash
make test
```

Tests the full workflow: import → compile → serve → HTTP queries

**Unit tests** (requires OCaml):

```bash
make test-unit
```

Tests individual components (Git backend, Pack backend, parsing)

## License

MIT
