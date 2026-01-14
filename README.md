# BeingDB

**Structured facts for RAG, versioned like Git.**

BeingDB is a lightweight fact store for RAG applications. Store predicates (entities, relationships, metadata) and query them with joins. Simple atoms and quoted strings - your LLM handles the reasoning.

**Why BeingDB:**
- **Fast queries** - Optimized read-only snapshots
- **Git workflow** - Version control, branching, merging for knowledge
- **Join support** - Connect entities across predicates  
- **RAG-ready** - Pairs with semantic search

Perfect for chatbots, research archives, and applications where you need structured metadata alongside vector search.


## Quick Start

### With Docker

**Option 1: Import from local files**

Assuming you have predicates in individual files:
```
my-facts/
  created
  shown_in
  held_at
  keyword
```

```bash
docker compose build
docker compose run --rm -v ./my-facts:/data/facts:ro beingdb \
  beingdb-import --input /data/facts --git /data/git-store
docker compose run --rm beingdb beingdb-compile --git /data/git-store --pack /data/pack-store
docker compose up -d
```

**Option 2: Clone from Git**

```bash
docker compose build
docker compose run --rm beingdb beingdb-clone https://github.com/org/facts.git --git /data/git-store
docker compose run --rm beingdb beingdb-compile --git /data/git-store --pack /data/pack-store
docker compose up -d
```

**Update & deploy:**
```bash
# Pull updates
docker compose run --rm beingdb beingdb-pull --git /data/git-store

# Compile new version
docker compose run --rm beingdb beingdb-compile --git /data/git-store --pack /data/snapshots/v2

# Zero-downtime swap
ln -sfn ./snapshots/v2 ./current
docker compose restart
```

**Query:**
```bash
curl -X POST http://localhost:8080/query -d '{"query": "created(Artist, Work)"}'
```

Data persists in `./git-store` and `./pack-store`.

### Without Docker

```bash
opam install . --deps-only && dune build
dune exec beingdb-import -- --input ./my-facts --git ./store
dune exec beingdb-compile -- --git ./store --pack ./pack
dune exec beingdb-serve -- --pack ./pack --port 8080
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

## License

MIT
