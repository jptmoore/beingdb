#!/bin/bash
# Test BeingDB query language with example find/where queries

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
  -d '{"query": "find Work\nwhere\n  created(tina_keane, Work)"}' | jq .

echo
echo -e "${YELLOW}2. Two-predicate join: Where were tina_keane's works shown?${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Work, Exhibition\nwhere\n  created(tina_keane, Work)\n  shown_in(Work, Exhibition)"}' | jq .

echo
echo -e "${YELLOW}3. Three-way join: Which venues showed tina_keane's works?${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Work, Exhibition, Venue\nwhere\n  created(tina_keane, Work)\n  shown_in(Work, Exhibition)\n  held_at(Exhibition, Venue)"}' | jq .

echo
echo -e "${YELLOW}4. Filter by medium: Find all video works${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Work\nwhere\n  uses_medium(Work, video)"}' | jq .

echo
echo -e "${YELLOW}5. Multi-attribute join: Video works with creation years${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Work, Year\nwhere\n  uses_medium(Work, video)\n  created_in_year(Work, Year)"}' | jq .

echo
echo -e "${YELLOW}6. Reverse query: Which artists showed work at ICA London?${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Artist, Work, Exhibition\nwhere\n  created(Artist, Work)\n  shown_in(Work, Exhibition)\n  held_at(Exhibition, ica_london)"}' | jq .

echo
echo -e "${YELLOW}7. Complete profile: Everything about 'she'${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Artist, Exhibition, Year, Medium\nwhere\n  created(Artist, she)\n  shown_in(she, Exhibition)\n  created_in_year(she, Year)\n  uses_medium(she, Medium)"}' | jq .

echo
echo -e "${YELLOW}8. Pagination: First 2 works${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Artist, Work\nwhere\n  created(Artist, Work)\norder by Work\nlimit 2\noffset 0"}' | jq .

echo
echo -e "${YELLOW}9. Pagination: Next 2 works (offset=2)${NC}"
curl -s -X POST $BASE_URL/query \
  -H 'Content-Type: application/json' \
  -d '{"query": "find Artist, Work\nwhere\n  created(Artist, Work)\norder by Work\nlimit 2\noffset 2"}' | jq .

echo
echo -e "${GREEN}All tests complete!${NC}"
