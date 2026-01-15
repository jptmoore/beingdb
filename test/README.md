# Testing Guide

## Quick Start

```bash
# Run unit tests
make test

# Or directly with dune
dune test
```

## Test Structure

### Unit Tests (Alcotest)
**File**: `test/test_beingdb.ml`

Tests individual components in isolation:
- Fact parsing (`parse_fact`)
- Git backend read/write
- Pack backend queries and pattern matching

**Run**: `dune test`

### Integration Testing (Manual)

For end-to-end testing, run the workflow manually:

```bash
# Setup example data
cd examples && bash setup_examples.sh && cd ..

# Import
dune exec beingdb-import -- --input ./examples/data --git ./git-store

# Compile
dune exec beingdb-compile -- --git ./git-store --pack ./pack-store

# Serve
dune exec beingdb-serve -- --pack ./pack-store --port 8080 &

# Test queries
bash test/integration_test.sh

# Cleanup
pkill beingdb-serve
rm -rf git-store pack-store examples/data
```

## Test Data

Example predicates are in `examples/sample_predicates.pl`:
- `created(Artist, Work)` - Artwork creation facts
- `shown_in(Work, Exhibition)` - Exhibition facts
- `held_at(Exhibition, Venue)` - Venue facts

The integration test (`test/integration_test.sh`) verifies:
- API endpoints respond correctly
- Pattern matching works
- Joins return expected results
- Error handling works

## License

MIT
