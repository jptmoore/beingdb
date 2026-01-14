#!/bin/bash
# Docker-based integration test for BeingDB

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
  echo -e "${YELLOW}ℹ${NC} $1"
}

pass() {
  echo -e "${GREEN}✓${NC} $1"
}

fail() {
  echo -e "${RED}✗${NC} $1"
  exit 1
}

cleanup() {
  info "Cleaning up..."
  docker compose down -v 2>/dev/null || true
  # Always remove to ensure clean state
  rm -rf git-store pack-store examples/data
}

trap cleanup EXIT

info "Starting Docker-based BeingDB test..."

# CRITICAL: Clean everything before starting
info "Removing any existing stores..."
rm -rf git-store pack-store examples/data
pass "Clean slate confirmed"

# Setup example data
info "Setting up example data..."
cd examples && bash setup_examples.sh && cd ..
pass "Example data created"

# Build Docker image
info "Building Docker image..."
docker compose build || fail "Docker build failed"
pass "Docker image built"

# Import example data
info "Importing facts..."
docker compose run --rm -v ./examples/data:/data/facts:ro beingdb \
  beingdb-import --input /data/facts --git /data/git-store || fail "Import failed"
pass "Facts imported"

# Verify git store was created
if [ ! -d "git-store" ]; then
  fail "Git store directory not created"
fi
pass "Git store verified"

# Compile to pack
info "Compiling to pack..."
docker compose run --rm beingdb \
  beingdb-compile --git /data/git-store --pack /data/pack-store || fail "Compile failed"
pass "Compiled to pack"

# Verify pack store was created
if [ ! -f "pack-store/store.control" ]; then
  fail "Pack store not properly initialized"
fi
pass "Pack store verified"

# Start server
info "Starting server..."
docker compose up -d || fail "Server start failed"
sleep 3
pass "Server started"

# Test queries
info "Testing queries..."

# Test 1: List predicates
PREDICATES=$(curl -s http://localhost:8080/predicates)
if echo "$PREDICATES" | grep -q "created"; then
  pass "GET /predicates works"
else
  fail "GET /predicates failed"
fi

# Test 2: Pattern matching
RESULT=$(curl -s -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "created(tina_keane, Work)"}')
if echo "$RESULT" | grep -q "she"; then
  pass "Pattern matching works"
else
  fail "Pattern matching failed"
fi

# Test 3: Join query
RESULT=$(curl -s -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "created(tina_keane, Work), shown_in(Work, Exhibition)"}')
if echo "$RESULT" | grep -q "rewind_exhibition_1995"; then
  pass "Join query works"
else
  fail "Join query failed"
fi

# Test 4: String query
RESULT=$(curl -s -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "description(she, Desc)"}')
if echo "$RESULT" | grep -q "pioneering video work"; then
  pass "String query works"
else
  fail "String query failed"
fi

# Test 5: Three-way join
RESULT=$(curl -s -X POST http://localhost:8080/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition), held_at(Exhibition, Venue)"}')
if echo "$RESULT" | grep -q "ica_london"; then
  pass "Three-way join works"
else
  fail "Three-way join failed"
fi

info "All tests passed!"
echo -e "${GREEN}✓ Docker integration test complete${NC}"
