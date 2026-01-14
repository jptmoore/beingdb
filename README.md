# BeingDB

A logic-based knowledge store: **Git for humans, Pack for machines**.

- Clone Git repositories into Irmin Git (shallow, HEAD only)
- Pull updates and merge with Irmin Git
- Compile to immutable Pack snapshots
- Serve fast queries from Pack only

**Architecture:** Clone (shallow) → Pull/Merge → Compile (Git HEAD → Pack) → Serve (Pack only)

## Bootstrap Sequence

```bash
# 1. Clone facts repository into Irmin Git
beingdb-clone https://github.com/org/beingdb-facts.git

# 2. Compile predicates from Irmin Git to Pack
beingdb-compile

# 3. Serve queries from Pack
beingdb-serve
```

**Key insight:** Runtime never touches Git (remote or local). Only reads compiled Pack snapshots.

## Quick Start with Examples

Try BeingDB with the included art history dataset:

### 1. Install and Build

```bash
# Install OCaml dependencies (requires OCaml 4.14+)
opam install . --deps-only

# Build BeingDB
dune build
```

### 2. Setup Example Data

The example data comes from `examples/sample_predicates.pl` - an art history dataset with facts about artworks, artists, exhibitions, and venues.

```bash
# Extract predicates into separate files (emulates a Git repository structure)
cd examples && bash setup_examples.sh && cd ..
# Creates examples/data/ with 5 predicate files:
#   created (3 facts) - artist/artwork relationships
#   shown_in (3 facts) - artwork/exhibition relationships
#   held_at (2 facts) - exhibition/venue relationships
#   created_in_year (3 facts) - artwork creation dates
#   uses_medium (3 facts) - artwork mediums
# 
# This structure mimics what would be in a remote Git repository
# that you'd clone with: beingdb-clone https://github.com/org/facts.git
```

### 3. Import and Compile

```bash
# Import from examples/data/ to Git store (development equivalent of beingdb-clone)
dune exec beingdb-import -- --input examples/data --git ./git-store

# Compile to Pack store
dune exec beingdb-compile -- --git ./git-store --pack ./pack-store
```

**Note:** If you get a lock error, stop the running server first:
```bash
# Find and kill running server
pkill -f beingdb-serve
```

### 4. Start Server

```bash
# Start query server
dune exec beingdb-serve -- --pack ./pack-store --port 8080
```

### 5. Query the Database

BeingDB uses a Prolog-style query language with pattern matching and joins:

```bash
# List all predicates
curl http://localhost:8080/predicates

# Simple pattern: Find all works by tina_keane
curl -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "created(tina_keane, Work)"}'

# Use wildcards: Find what medium "she" uses
curl -X POST http://localhost:8080/query \
  -d '{"query": "uses_medium(she, _)"}'

# Two-predicate join: Where were tina_keane's works exhibited?
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(tina_keane, Work), shown_in(Work, Exhibition)"}'

# Three-way join: Which venues showed tina_keane's works?
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(tina_keane, Work), shown_in(Work, Exhibition), held_at(Exhibition, Venue)"}'

# Multiple attributes: Find all video works with their creation years
curl -X POST http://localhost:8080/query \
  -d '{"query": "uses_medium(Work, video), created_in_year(Work, Year)"}'
```

**Query Language Syntax:**
- **Variables** start with uppercase: `Work`, `Artist`, `Exhibition`
- **Atoms** start with lowercase: `tina_keane`, `she`, `video`  
- **Wildcard**: `_` matches anything
- **Joins**: Comma-separated predicates with shared variables

**Run all example queries:**
```bash
bash examples/test_queries.sh
```

## Operational Workflow

### Production Setup

```bash
# 1. Clone remote facts repository (shallow Irmin Git)
beingdb-clone https://github.com/org/beingdb-facts.git

# 2. Compile from Irmin Git HEAD to Pack
beingdb-compile

# 3. Serve queries from Pack (no Git dependency)
beingdb-serve
```

### Getting Updates

When upstream has changes:

```bash
# 1. Pull and merge in Irmin Git (handles conflicts)
beingdb-pull

# 2. Recompile to new Pack snapshot
beingdb-compile --pack ./snapshots/pack-$(date +%s)

# 3. Hot reload using one of the strategies below
```

### Zero-Downtime Deployment

#### Strategy 1: Atomic Symlink Swap

```bash
# Compile to timestamped snapshot
beingdb-compile --pack ./snapshots/pack-20260114-162000

# Atomically update symlink
ln -sfn ./snapshots/pack-20260114-162000 ./pack-current

# Server watches pack-current symlink and reloads on change
beingdb-serve --pack ./pack-current
```

#### Strategy 2: Blue-Green Deployment

```bash
# Keep two servers running
beingdb-serve --pack ./pack-blue --port 8080 &
beingdb-serve --pack ./pack-green --port 8081 &

# Update green, test, then switch load balancer
beingdb-compile --pack ./pack-green
# Load balancer: 8080 → 8081

# Update blue, switch back
beingdb-compile --pack ./pack-blue
# Load balancer: 8081 → 8080
```

See deployment strategies in Architecture section below.

**Production patterns:**
- Compile once in CI, deploy snapshot to all instances
- Use versioned snapshots (by git SHA, timestamp, or semantic version)
- Health checks ensure new snapshot loads correctly before next instance updates
- Rollback = point symlink to previous snapshot
- No Git operations in production runtime

**Key insight:** 
- All Git operations (pull, merge, conflict resolution) happen **before** compilation
- Compilation happens once (in CI or staging)
- Pack snapshots are immutable artifacts
- Runtime never touches Git, only loads Pack snapshots
- Updates flow: Git → Compile (CI) → Artifact Storage → Rolling Deploy → Runtime

## Predicate Format

Predicates are flat, single-line facts:

```prolog
predicate_name(arg1, arg2, arg3).
```

**Rules:**
- Lowercase predicate names with underscores
- Arguments separated by commas
- Optional trailing period
- Comments start with `%` or `#`
- One fact per line

**Examples:**
```prolog
% Valid facts
created(tina_keane, she).
shown_in(she, rewind_exhibition_1995)
held_at(rewind_exhibition_1995, ica_london).

# This is also a comment
created(yoko_ono, cut_piece).
```

## API Reference

### `GET /predicates`
List all predicates in the Pack store.

**Example:**
```bash
curl http://localhost:8080/predicates
```

### `GET /query/:predicate`
Get all facts for a predicate.

**Example:**
```bash
curl http://localhost:8080/query/created
```

**Response:**
```json
{
  "predicate": "created",
  "facts": [["tina_keane", "she"], ["tina_keane", "faded_wallpaper"]]
}
```

### `POST /query`
Execute queries with pattern matching and joins.

**Request:**
```json
{
  "query": "created(Artist, Work), shown_in(Work, Exhibition)"
}
```

**Response:**
```json
{
  "variables": ["Artist", "Work", "Exhibition"],
  "results": [
    {"Artist": "tina_keane", "Work": "she", "Exhibition": "rewind_exhibition_1995"}
  ],
  "count": 1
}
```

**Query Syntax:**
- **Variables**: Uppercase (`Work`, `Artist`) - bind to values
- **Atoms**: Lowercase (`tina_keane`, `video`) - match exactly
- **Wildcard**: `_` - match anything (unbound)
- **Joins**: Comma-separated predicates with shared variables

**Examples:**
```bash
# Pattern matching with wildcard
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(tina_keane, _)"}'

# Pattern matching with variable
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(tina_keane, Work)"}'

# Join across multiple predicates
curl -X POST http://localhost:8080/query \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition), held_at(Exhibition, Venue)"}'
```

## CLI Commands

### `beingdb-clone`

Clone remote facts repository into Irmin Git (shallow, HEAD only).

```bash
beingdb-clone REPO_URL [OPTIONS]

Arguments:
  REPO_URL            Remote Git repository URL

Options:
  --git, -g DIR       Irmin Git store directory (default: ./git-store)

Example:
  beingdb-clone https://github.com/org/beingdb-facts.git
```

### `beingdb-pull`

Pull updates from remote and merge into Irmin Git.

```bash
beingdb-pull [OPTIONS]

Options:
  --git, -g DIR       Irmin Git store directory (default: ./git-store)
  --remote REMOTE     Remote name (default: origin)
  --branch BRANCH     Branch name (default: main)

Example:
  beingdb-pull
```

### `beingdb-compile`

Compile from Irmin Git HEAD to Pack snapshot.

```bash
beingdb-compile [OPTIONS]

Options:
  --git, -g DIR       Irmin Git store directory (default: ./git-store)
  --pack, -p DIR      Output Pack store directory (default: ./pack-store)

Example:
  beingdb-compile --pack ./snapshots/pack-20260114-162000
```

### `beingdb-serve`

Serve queries from Pack store (read-only, no Git dependency).

```bash
beingdb-serve [OPTIONS]

Options:
  --pack, -p DIR      Pack store directory (default: ./pack-store)
  --port PORT         Server port (default: 8080)

Example:
  beingdb-serve --pack ./pack-store --port 8080
```

### Development Tools

#### `beingdb-import`

Import flat files into Irmin Git (for testing/development).

```bash
beingdb-import --input DIR --git DIR

Options:
  --input, -i DIR     Input directory with flat predicate files
  --git, -g DIR       Irmin Git store directory

Example:
  beingdb-import --input ./test_data --git ./git-store
```

## Development

### Building

```bash
# Build the project
dune build

# Build in watch mode (auto-rebuild on changes)
dune build --watch

# Clean build artifacts
dune clean
```

### Running (Development Mode)

```bash
# With dune exec (use dash form)
dune exec beingdb-import -- --input ./test_data --git ./git-store
dune exec beingdb-compile -- --git ./git-store --pack ./pack-store
dune exec beingdb-serve -- --pack ./pack-store --port 8080

# Or run binaries directly after building
dune build
./_build/default/bin/serve.exe --pack ./pack-store --port 8080
```

**Note:** After `opam install`, commands are available as `beingdb-import`, `beingdb-compile`, `beingdb-serve`.

## Architecture

**Three-layer design:** `Remote Git → Irmin Git (shallow) → Irmin Pack → Runtime`

**Key principles:**
1. Runtime never reads Git - only Pack snapshots
2. All merging happens in Irmin Git (handles conflicts)
3. Compiler reads HEAD only - Irmin Git is shallow (no history)
4. Pack maintains full history - append-only snapshot lineage
5. Pack is sole runtime dependency

**Data flow:**
```
GitHub → beingdb-clone → Irmin Git (HEAD only)
                            ↓ beingdb-pull (merge updates)
                         Git HEAD
                            ↓ beingdb-compile (validate, emit)
                         Pack Snapshot
                            ↓ beingdb-serve (queries)
                         REST API
```

**Deployment:**
- Compile once in CI, deploy snapshot to all instances
- Use versioned snapshots (git SHA, timestamp, or semantic version)
- Rolling deploy with symlink swap or blue-green
- Rollback = point to previous snapshot

## Project Structure

```
beingdb/
├── lib/
│   ├── git_backend.ml       # Irmin Git (intermediate layer)
│   ├── pack_backend.ml      # Irmin Pack (runtime queries)
│   ├── parse_predicate.ml   # Predicate fact parsing
│   ├── query_parser.ml      # Query language parser
│   ├── query_engine.ml      # Join execution engine
│   ├── sync.ml              # Git → Pack sync
│   ├── api.ml               # REST API
│   └── beingdb.ml           # Public interface
├── bin/
│   ├── clone.ml             # Clone remote → Irmin Git
│   ├── pull.ml              # Pull and merge
│   ├── compile.ml           # Git HEAD → Pack
│   ├── serve.ml             # Pack → HTTP
│   ├── import.ml            # Flat files → Git (dev)
│   └── main.ml              # Command dispatcher
├── examples/
│   ├── sample_predicates.pl # Example art history data
│   ├── setup_examples.sh    # Setup script
│   └── test_queries.sh      # Query test script
└── test/
    ├── test_beingdb.ml      # Unit tests
    └── *.sh                 # Test scripts
```

## Testing

```bash
# Run unit tests
dune test

# Run example queries
bash examples/setup_examples.sh
dune exec beingdb-import -- --input examples/data --git git-store
dune exec beingdb-compile -- --git git-store --pack pack-store
dune exec beingdb-serve -- --pack pack-store --port 8080 &
bash examples/test_queries.sh
```

## Contributing

1. Write tests first (Alcotest)
2. Run full suite: `dune test`
3. Update README for new features
4. Ensure build: `dune build`

## Dependencies

- **OCaml**: 4.14.0 or later
- **Irmin**: 3.11.0 (irmin.unix, irmin-git.unix, irmin-pack.unix)
- **Dream**: 1.0.0~alpha5 (web framework)
- **Lwt**: 5.6.0 (async I/O)
- **Cmdliner**: 1.3.0 (CLI parsing)
- **Yojson**: 2.0.0 (JSON handling)
- **Logs**: 0.7.0 (logging)
- **Alcotest**: 1.7.0 (testing)

Install all dependencies:
```bash
opam install . --deps-only
```

## License

MIT

---

**BeingDB** — Logic-based knowledge store with Git history and Pack performance  
Built with Irmin • Powered by OCaml
