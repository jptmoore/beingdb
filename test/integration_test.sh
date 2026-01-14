#!/bin/bash
# Integration test for BeingDB API

set -e

BASE_URL="${BASE_URL:-http://localhost:8080}"
FAIL_COUNT=0
PASS_COUNT=0

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test helper functions
pass() {
  echo -e "${GREEN}✓${NC} $1"
  ((PASS_COUNT++))
}

fail() {
  echo -e "${RED}✗${NC} $1"
  ((FAIL_COUNT++))
}

info() {
  echo -e "${YELLOW}ℹ${NC} $1"
}

test_endpoint() {
  local name="$1"
  local url="$2"
  local expected_pattern="$3"
  
  response=$(curl -s "$url")
  
  if echo "$response" | grep -q "$expected_pattern"; then
    pass "$name"
    return 0
  else
    fail "$name"
    echo "  Expected pattern: $expected_pattern"
    echo "  Got: $response"
    return 1
  fi
}

# Start tests
echo "========================================="
echo "BeingDB Integration Tests"
echo "========================================="
echo ""

info "Testing against: $BASE_URL"
echo ""

# Test 1: List predicates
info "Test 1: List all predicates"
test_endpoint "GET /predicates returns JSON" \
  "$BASE_URL/predicates" \
  '"predicates"'

# Test 2: Query all facts for a predicate
info "Test 2: Query all facts for 'created'"
test_endpoint "GET /query/created returns facts" \
  "$BASE_URL/query/created" \
  'tina_keane'

# Test 3: Pattern matching - get all works by tina_keane
info "Test 3: Pattern match - works by tina_keane"
test_endpoint "GET /query/created?args=tina_keane,_ matches pattern" \
  "$BASE_URL/query/created?args=tina_keane,_" \
  'she'

# Test 4: Pattern matching - where was 'she' shown?
info "Test 4: Pattern match - where was 'she' shown"
test_endpoint "GET /query/shown_in?args=she,_ finds exhibitions" \
  "$BASE_URL/query/shown_in?args=she,_" \
  'rewind_exhibition_1995'

# Test 5: Query predicate with multiple facts
info "Test 5: Query uses_medium predicate"
test_endpoint "GET /query/uses_medium returns mediums" \
  "$BASE_URL/query/uses_medium" \
  'video'

# Test 6: Trigger sync
info "Test 6: Trigger manual sync"
response=$(curl -s -X POST "$BASE_URL/sync")
if echo "$response" | grep -q "sync completed"; then
  pass "POST /sync triggers sync"
else
  fail "POST /sync failed"
  echo "  Got: $response"
fi

# Test 7: Verify data persists after sync
info "Test 7: Query after sync"
test_endpoint "GET /query/created still works after sync" \
  "$BASE_URL/query/created" \
  'bruce_nauman'

echo ""
echo "========================================="
echo "Test Summary"
echo "========================================="
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed${NC}"
  exit 1
fi
