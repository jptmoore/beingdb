# BeingDB

**Facts versioned like code, queried like a database.**

Modern RAG systems retrieve unstructured text well, but struggle with structured facts. Vector search finds similar documents, but can't reliably answer "Who created this artwork?", "Where was this shown?", or "Which entities are connected through relationships?"

BeingDB solves this by treating facts like source code: **store them in Git, query them from an optimized runtime**.

Your knowledge base evolves like a codebase. Subject matter experts who already use Git for documentation can contribute facts using the same workflow.

BeingDB uses the same storage technology that powers the Tezos blockchain, giving your facts blockchain-grade immutability and integrity. **Deploy across multiple locations for digital preservation**—each location independently syncs from Git to create verifiable identical copies, ensuring your knowledge base survives any single point of failure.

## Simple Query Language

Facts are Prolog-style predicates—one fact per line:
```prolog
created(tina_keane, shadow_of_a_journey).
shown_in(shadow_of_a_journey, rewind_exhibition_1995).
held_at(rewind_exhibition_1995, ica_london).
```

Query with pattern matching and joins:
```
created(Artist, Work), shown_in(Work, Exhibition)
```

No schema, no complex rules. Your LLM handles reasoning; BeingDB provides the reliable, joinable facts.

## Quick Start

```bash
# Clone sample facts
beingdb-clone https://github.com/jptmoore/beingdb-sample-facts.git --git ./git_store

# Compile to optimized format
beingdb-compile --git ./git_store --pack ./pack_store

# Start server
beingdb-serve --pack ./pack_store

# Query (in another terminal)
curl -X POST http://localhost:8080/query -d '{"query": "created(Artist, Work)"}'
```

## Documentation

- **[Getting Started](docs/getting-started.md)** - Complete tutorial with examples
- **[Installation](docs/installation.md)** - Platform-specific setup
- **[Query Language](docs/query-language.md)** - Patterns, joins, optimization
- **[API Reference](docs/api.md)** - HTTP API documentation
- **[Deployment](docs/deployment.md)** - Production Docker deployment
- **[Digital Preservation](docs/digital-preservation.md)** - Multi-region setup and disaster recovery
- **[Internals](docs/internals.md)** - Storage architecture and encoding format

**Example facts repository:** [beingdb-sample-facts](https://github.com/jptmoore/beingdb-sample-facts)

## License

MIT
