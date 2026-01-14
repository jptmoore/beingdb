# BeingDB

**Structured facts for RAG, versioned like Git.**

BeingDB is a lightweight fact store for RAG applications. Store predicates (entities, relationships, metadata) and query them with joins. Simple atoms and quoted strings - your LLM handles the reasoning.

**Why BeingDB:**
- **Fast queries** - Optimized read-only snapshots (Irmin Pack)
- **Git workflow** - Version control, branching, merging for knowledge
- **Join support** - Connect entities across predicates  
- **RAG-ready** - Pairs with semantic search (Annosearch, pgvector, etc.)

Perfect for chatbots, research archives, and applications where you need structured metadata alongside vector search.


## Quick Start

### Install

```bash
opam install . --deps-only
dune build
```

### Create Knowledge Base

```bash
# Import facts from files
dune exec beingdb-import -- --input ./my-facts --git ./store

# Compile to fast query format  
dune exec beingdb-compile -- --git ./store --pack ./pack

# Serve via REST API
dune exec beingdb-serve -- --pack ./pack --port 8080
```

### Query

### Query

```bash
# Simple pattern matching
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work)"}'

# Joins across predicates
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition)"}'

# With quoted strings
curl -X POST http://localhost:8080/query \
  -d '{"query": "keyword(Doc, \"machine learning\")"}'
```

## Example: Art Archive

**Facts** (`examples/sample_predicates.pl`):
```prolog
created(tina_keane, she).
created_in_year(she, 1979).
shown_in(she, rewind_exhibition_1995).
held_at(rewind_exhibition_1995, ica_london).
description(she, "A pioneering video work").
```

**Query** - "Where was Tina Keane's work shown?":
```prolog
created(tina_keane, Work), shown_in(Work, Exhibition), held_at(Exhibition, Venue)
```

**Result**:
```json
{
  "variables": ["Work", "Exhibition", "Venue"],
  "results": [
    {"Work": "she", "Exhibition": "rewind_exhibition_1995", "Venue": "ica_london"}
  ]
}
```

Try it: `cd examples && bash setup_examples.sh && cd .. && dune exec beingdb-import -- --input examples/data --git ./git-store && dune exec beingdb-compile -- --git ./git-store --pack ./pack-store && dune exec beingdb-serve -- --pack ./pack-store`

## Git-Like Workflow

**Version your knowledge:**
```bash
beingdb-clone https://github.com/org/facts.git  # Clone remote repo
beingdb-pull                                     # Pull updates
beingdb-compile --pack ./snapshots/v2            # Compile new version
```

**Deploy updates:**
```bash
# Point symlink to new snapshot (zero downtime)
ln -sfn ./snapshots/v2 ./current
beingdb-serve --pack ./current
```

Rollback = switch symlink back. All Git operations happen before deployment - runtime only reads immutable Pack snapshots.

## Query Language

**Terms:**
- **Variables**: Uppercase (`Work`, `Artist`) - bind to values
- **Atoms**: Lowercase identifiers (`tina_keane`, `1979`)  
- **Strings**: Quoted text (`"machine learning"`)
- **Wildcard**: `_` - matches anything

**Queries:**
- Single: `created(tina_keane, Work)`
- Joins: `created(Artist, Work), shown_in(Work, Venue)`
- Mixed: `keyword(Doc, "AI"), authored_by(Doc, Author)`

## RAG Integration

**Typical architecture:**
1. **Semantic search** (Annosearch/pgvector) → Find relevant chunks by similarity
2. **BeingDB** → Get structured metadata, entities, relationships
3. **LLM** → Combine both for contextualized answers

**Example RAG facts:**
```prolog
chunk_of(chunk_123, doc_456).
keyword(doc_456, "neural networks").
authored_by(doc_456, "Jane Smith").
published_year(doc_456, 2024).
```

BeingDB retrieves structure; LLM does temporal reasoning, comparisons, interpretation.

## API

**`GET /predicates`** - List all predicates
**`GET /query/:predicate`** - Get all facts for a predicate  
**`POST /query`** - Execute query with joins

Request: `{"query": "created(Artist, Work), shown_in(Work, Exhibition)"}`  
Response: `{"variables": [...], "results": [...], "count": N}`

## Production

**Commands:**
- `beingdb-clone <url>` - Clone Git repo
- `beingdb-pull` - Pull updates
- `beingdb-compile` - Git → Pack snapshot
- `beingdb-serve` - Serve queries

**Deployment:**
Compile once in CI → Deploy snapshots → Rolling updates via symlink swap

## Architecture

```
Git Repo (human edits) → Irmin Git → Compile → Pack Snapshot → Query API
```

- **Git layer**: Version control, collaboration, merging
- **Pack layer**: Fast queries, immutable snapshots
- **Runtime**: Zero Git dependency, reads Pack only

## License

MIT
