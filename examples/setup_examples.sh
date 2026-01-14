#!/bin/bash
# Setup example data for BeingDB tutorial

set -e

echo "Setting up BeingDB example data..."
echo

# Create data directory
mkdir -p data

# Extract predicates from sample_predicates.pl
echo "Extracting predicates..."

grep "^created(" sample_predicates.pl > data/created
grep "^shown_in(" sample_predicates.pl > data/shown_in
grep "^held_at(" sample_predicates.pl > data/held_at
grep "^created_in_year(" sample_predicates.pl > data/created_in_year
grep "^uses_medium(" sample_predicates.pl > data/uses_medium

echo "✓ Extracted 5 predicate files to examples/data/"
echo
echo "Files created:"
ls -1 data/
echo
echo "Fact counts:"
for file in data/*; do
  name=$(basename "$file")
  count=$(wc -l < "$file" | tr -d ' ')
  echo "  $name: $count facts"
done
echo
echo "Ready to import! Run:"
echo "  dune exec beingdb-import -- --input examples/data --git ./git-store"
