# BeingDB

**Facts versioned like code, queried like a database.**

BeingDB is a lightweight database for structured facts maintained in Git.

Facts are written as simple predicates:

```text
created(tina_keane, shadow_of_a_journey).
shown_in(shadow_of_a_journey, rewind_exhibition_1995).
held_at(rewind_exhibition_1995, ica_london).
year_created(shadow_of_a_journey, @1979).
```

BeingDB compiles those facts into an optimized, read-only store that can be queried through an HTTP API or interactive REPL.

## Why BeingDB?

RAG systems are good at retrieving relevant text, but some questions are better answered from explicit structured facts. BeingDB provides a factual layer that can sit alongside document retrieval:

- **Git-versioned knowledge** — facts are plain text and can be reviewed, changed and versioned like source code.
- **Fast read-only runtime** — compile a Git repository into an optimized store for serving.
- **Simple query language** — pattern matching, joins, variables and typed comparisons.
- **LLM-friendly** — language models can discover available predicates through the API, then construct and validate queries against structured facts rather than inferring them from retrieved text.
- **No inference engine required** — BeingDB handles factual retrieval and joins; reasoning stays with the consuming application or LLM.

No schema-heavy knowledge graph or complex rule system is required. Your application or LLM handles reasoning; BeingDB provides reliable, joinable facts.

## Query facts

Queries use the same predicate syntax as the underlying facts:

```text
created(Artist, Work)
```

returns artists and the works they created. Comma-separated patterns join on shared variables and can include typed comparisons:

```text
created(Artist, Work),
year_created(Work, Y),
Y >= 1970,
shown_in(Work, Exhibition)
```

> Which works created after 1970 were subsequently shown in an exhibition?

Whitespace is insignificant, so a query can be written on one line or across several -- this is what makes it convenient to send as a single-line JSON string over the REST API. See [Query Language](docs/query-language.md) for the full syntax reference.

## Quick start

Clone some example facts, compile them, and start the server:

```bash
beingdb-clone https://github.com/jptmoore/beingdb-sample-facts.git --git ./git_store
beingdb-compile --git ./git_store --pack ./pack_store
beingdb-serve --pack ./pack_store
```

## HTTP API

```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition)"}'
```

The API also exposes the predicates available in the compiled database, so applications and LLMs can discover the vocabulary they can query. See the [API documentation](docs/api.md) for pagination, comparisons, validation, safety limits and error responses.

## REPL

```bash
beingdb repl --pack ./pack_store
```

```text
beingdb> created(Artist, Work)
```

See [Getting Started](docs/getting-started.md#interactive-repl) for the full command reference.

## How it works

BeingDB separates authoring from serving:

```text
Git repository
      |
      v
beingdb-compile
      |
      v
Compiled store
      |
      +-- HTTP API
      +-- REPL
```

The **Git repository remains the source of truth** -- facts are edited using normal development workflows (commits, branches, pull requests, review, version history). `beingdb-compile` transforms those source facts into an optimized, read-only store; `beingdb-serve` and the REPL open that store and expose it through the query interfaces. This keeps the runtime simple and deployments reproducible.

## Features

- Git-backed fact authoring
- Compiled read-only runtime
- Predicate-based fact model
- Variables and pattern matching
- Multi-predicate joins
- Typed values and comparisons
- HTTP query API
- Interactive REPL
- Predicate/vocabulary discovery
- Designed for use with LLM and RAG systems
- Lightweight deployment model
- Configurable safety limits (timeouts, result caps, query size, concurrency) to guard against expensive or malicious queries

## Example facts

A sample repository is available at:

[github.com/jptmoore/beingdb-sample-facts](https://github.com/jptmoore/beingdb-sample-facts)

It provides a small dataset that can be cloned, compiled and queried with BeingDB.

## Documentation

More detailed documentation is available in the `docs` directory:

- [Installation](docs/installation.md)
- [Getting Started](docs/getting-started.md)
- [Query Language](docs/query-language.md)
- [API Reference](docs/api.md)
- [Internals](docs/internals.md)

## Building from source

Clone the repository:

```bash
git clone https://github.com/jptmoore/beingdb.git
cd beingdb
```

Follow the [installation documentation](docs/installation.md) for build requirements and setup.

## Project status

BeingDB is under active development.

The project is exploring a deliberately small approach to structured factual retrieval: maintain human-readable facts in Git, compile them into an efficient runtime representation, and expose a query interface that applications and language models can use directly.

Issues, experiments and contributions are welcome.

## License

MIT
