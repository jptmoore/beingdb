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

RAG systems are good at retrieving relevant text, but some questions are better answered from explicit structured facts.

BeingDB provides a factual layer that can sit alongside document retrieval:

- **Git-versioned knowledge** — facts are plain text and can be reviewed, changed and versioned like source code.
- **Fast read-only runtime** — compile a Git repository into an optimized store for serving.
- **Simple query language** — pattern matching, joins, variables and typed comparisons.
- **LLM-friendly** — language models can discover available predicates and construct queries against structured facts.
- **Reliable factual retrieval** — BeingDB returns explicit facts rather than asking a language model to infer them from retrieved text.
- **No inference engine required** — BeingDB handles factual retrieval and joins; reasoning can remain with the consuming application or LLM.

No schema-heavy knowledge graph or complex rule system is required. Your application or LLM handles reasoning; BeingDB provides reliable, joinable facts.

## Query facts

Queries use the same predicate syntax as the underlying facts.

A simple query:

```text
created(Artist, Work)
```

returns artists and the works they created.

Queries can also join multiple relationships:

```text
created(Artist, Work),
year_created(Work, Y),
Y >= 1970,
shown_in(Work, Exhibition)
```

This can answer questions such as:

> Which works created after 1970 were subsequently shown in an exhibition?

BeingDB performs the factual lookup and joins while the consuming application decides how to interpret or present the results.

## Designed for LLMs

BeingDB is intended to work particularly well as a structured factual component in an LLM or RAG stack.

Instead of relying on semantic retrieval for every question, an LLM can query explicit relationships when the answer depends on known facts.

For example, a system might use:

- document search for descriptive or contextual information;
- BeingDB for entities, relationships, dates and other structured facts;
- the LLM for reasoning and natural-language responses.

The API exposes the available predicates so an LLM can discover the vocabulary before constructing queries.

For MCP-based integrations, see the [BeingDB MCP server](https://github.com/jptmoore/beingdb-mcp).

## Quick start

Clone some example facts:

```bash
beingdb-clone \
  https://github.com/jptmoore/beingdb-sample-facts.git \
  --git ./git_store
```

Compile the Git repository:

```bash
beingdb-compile \
  --git ./git_store \
  --pack ./pack_store
```

Start the HTTP server:

```bash
beingdb-serve \
  --pack ./pack_store
```

BeingDB is now ready to query.

## HTTP API

Query the database:

```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query":"created(Artist, Work)"}'
```

A multi-predicate query can perform joins:

```bash
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query":"created(Artist, Work), shown_in(Work, Exhibition)"}'
```

The API can also expose the predicates available in the compiled database, allowing applications and LLMs to discover the vocabulary they can query.

See the [API documentation](docs/api.md) for details.

## REPL

BeingDB also includes an interactive REPL:

```bash
beingdb repl --pack ./pack_store
```

For example:

```text
beingdb> created(Artist, Work)
```

or:

```text
beingdb> created(Artist, Work), shown_in(Work, Exhibition)
```

The REPL uses the predicates in the database to provide a query environment tailored to the available facts.

## Example

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

## License

MIT
