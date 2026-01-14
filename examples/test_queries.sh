#!/bin/bash
# Test BeingDB query language with example queries

BASE_URL="${BASE_URL:-http://localhost:8080}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== BeingDB Query Language Tests ===${NC}"
echo

echo -e "${YELLOW}1. Simple pattern: Find all works by tina_keane${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "created(tina_keane, Work)"}' | jq .

echo
echo -e "${YELLOW}2. Two-predicate join: Where were tina_keane's works shown?${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "created(tina_keane, Work), shown_in(Work, Exhibition)"}' | jq .

echo
echo -e "${YELLOW}3. Three-way join: Which venues showed tina_keane's works?${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "created(tina_keane, Work), shown_in(Work, Exhibition), held_at(Exhibition, Venue)"}' | jq .

echo
echo -e "${YELLOW}4. Filter by medium: Find all video works${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "uses_medium(Work, video)"}' | jq .

echo
echo -e "${YELLOW}5. Multi-attribute join: Video works with creation years${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "uses_medium(Work, video), created_in_year(Work, Year)"}' | jq .

echo
echo -e "${YELLOW}6. Reverse query: Which artists showed work at ICA London?${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "created(Artist, Work), shown_in(Work, Exhibition), held_at(Exhibition, ica_london)"}' | jq .

echo
echo -e "${YELLOW}7. Complete profile: Everything about 'she'${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "created(Artist, she), shown_in(she, Exhibition), created_in_year(she, Year), uses_medium(she, Medium)"}' | jq .

echo
echo -e "${GREEN}All tests complete!${NC}"
