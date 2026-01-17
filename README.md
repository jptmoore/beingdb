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
You get a shared fact repository where curators add or correct information through small pull requests, editors review the changes, and the validated knowledge base redeploys automatically—treating cultural data with the same rigour and workflow as software.

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

**Installation:** See [Installation Guide](docs/installation.md) (requires OCaml 5.1+ and opam)

## Documentation

- **[Getting Started](docs/getting-started.md)** - Complete tutorial with examples
- **[Installation](docs/installation.md)** - Platform-specific setup
- **[Query Language](docs/query-language.md)** - Patterns, joins, optimization
- **[API Reference](docs/api.md)** - HTTP API documentation
- **[Deployment](docs/deployment.md)** - Production Docker deployment

**Example facts repository:** [beingdb-sample-facts](https://github.com/jptmoore/beingdb-sample-facts)

## License

MIT
