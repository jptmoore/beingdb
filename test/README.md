# Testing Guide

## Quick Start

```bash
# Setup test data and run all tests
make test-all

# Or run individual test suites:
make test              # Unit tests only
make integration-test  # API integration tests only
```

## Test Structure

### 1. Unit Tests (Alcotest)
**File**: `test/test_beingdb.ml`

Tests individual components in isolation:
- Fact parsing (`parse_fact`)
- Git backend read/write
- Pack backend queries and pattern matching

**Run**: `dune exec test/test_beingdb.exe`

### 2. Integration Tests (Shell Script)
**File**: `test/integration_test.sh`

Tests the full system end-to-end:
- API endpoints
- Sync pipeline
- Query functionality
- Pattern matching via HTTP

**Run**: `./test/integration_test.sh` (server must be running)

### 3. Test Data Setup
**File**: `test/setup_test_data.sh`

Creates sample predicates in `data/git/`:
- `created` - 5 facts
- `shown_in` - 4 facts
- `held_at` - 3 facts
- `created_in_year` - 5 facts
- `uses_medium` - 5 facts

**Run**: `./test/setup_test_data.sh`

## Testing Strategy for Early Development

### Phase 1: Core Functionality (Current)
✓ Unit tests for parsing and basic operations
✓ Integration tests for API
✓ Manual smoke tests via scripts

### Phase 2: Add Schema Support
- [ ] Schema parser tests
- [ ] Type validation tests
- [ ] Arity enforcement tests
- [ ] Error message quality tests

### Phase 3: Pack Backend Evolution
- [ ] Historical versioning tests
- [ ] Content-addressing tests
- [ ] Snapshot tests
- [ ] Performance benchmarks

### Phase 4: Query Engine
- [ ] Prolog-style query parser tests
- [ ] Join operation tests
- [ ] Query optimization tests

## Testing Best Practices

### For Each New Feature:
1. **Write unit test first** (TDD approach)
2. **Add integration test** for API surface
3. **Update test data** if new predicates needed
4. **Run full suite** before committing

### Test Organization:
```
test/
├── test_beingdb.ml       # Unit tests (Alcotest)
├── integration_test.sh   # API integration tests
├── setup_test_data.sh    # Test data creation
├── run_all_tests.sh      # Full test runner
└── dune                  # Test build config
```

### Quick Commands:
```bash
# Run unit tests
dune test

# Build and run unit tests manually
dune exec test/test_beingdb.exe

# Setup fresh test data
make setup-test-data

# Run integration tests (needs running server)
make integration-test

# Run everything
make test-all
```

## Example Test Workflow

```bash
# 1. Make code changes
vim lib/sync.ml

# 2. Run unit tests quickly
dune test

# 3. If tests pass, run integration tests
make setup-test-data
dune exec bin/main.exe -- --sync &
make integration-test
kill %1

# 4. Or use the all-in-one runner
make test-all
```

## Adding New Tests

### Add Unit Test:
Edit `test/test_beingdb.ml`:
```ocaml
let test_my_feature () =
  (* Your test here *)
  Alcotest.(check string) "description" "expected" "actual"

let () =
  Alcotest.run "BeingDB" [
    "MyModule", [
      Alcotest.test_case "my_feature" `Quick test_my_feature;
    ];
  ]
```

### Add Integration Test:
Edit `test/integration_test.sh`:
```bash
info "Test X: Description"
test_endpoint "Test name" \
  "$BASE_URL/endpoint" \
  "expected_pattern"
```

## Continuous Testing

When developing:
```bash
# Terminal 1: Watch mode (rebuilds on changes)
make watch

# Terminal 2: Run tests on each rebuild
while true; do dune test; sleep 2; done
```
