# BeingDB

**Facts versioned like code, queried like a database.**

Modern RAG systems retrieve unstructured text well, but struggle with structured facts. Vector search finds similar documents, but can't reliably answer "Who created this artwork?", "Where was this shown?", or "Which entities are connected through relationships?"

BeingDB solves this by treating facts like source code: **store them in Git, query them from an optimized runtime**.

Your knowledge base evolves like a codebase. Subject matter experts who already use Git for documentation can contribute facts using the same workflow.

## Simple Query Language

Facts are Prolog-style predicates—one fact per line—with types inferred directly from literal syntax (atoms, strings, language-tagged strings, integers, exact decimals, booleans, years, year-months, dates, UTC instants, and URIs):
```prolog
created(tina_keane, shadow_of_a_journey).
shown_in(shadow_of_a_journey, rewind_exhibition_1995).
held_at(rewind_exhibition_1995, ica_london).
year_created(shadow_of_a_journey, @1979).
confidence(assertion_1, 0.92).
```

Query with pattern matching, joins, and typed comparisons:
```
created(Artist, Work), year_created(Work, Y), Y >= 1970, shown_in(Work, Exhibition)
```

No schema, no complex rules. Your LLM handles reasoning; BeingDB provides the reliable, joinable, typed facts.

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

# ...or explore the same store interactively
beingdb repl --pack ./pack_store
```

## Interactive REPL

Prefer command-line interaction over writing `curl` commands? `beingdb repl` (or `beingdb-repl`) opens a compiled Pack store and runs queries straight from your terminal:

```
$ beingdb repl --pack ./pack_store
BeingDB REPL. Type :help for commands, :quit to exit.
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
beingdb> :quit
```

See [Getting Started](docs/getting-started.md#interactive-repl) for the full command reference, including `:explain`, `:predicates`, and loading facts or batches of queries from a file with `:load`.

## Documentation

- **[Installation](docs/installation.md)** - Platform-specific setup
- **[Getting Started](docs/getting-started.md)** - Complete tutorial with examples
- **[Query Language](docs/query-language.md)** - Patterns, joins, optimization
- **[API Reference](docs/api.md)** - HTTP API documentation
- **[Internals](docs/internals.md)** - Storage architecture and encoding format

**Example facts repository:** [beingdb-sample-facts](https://github.com/jptmoore/beingdb-sample-facts)

## License

MIT
