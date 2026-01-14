#!/bin/bash
# Setup test data for BeingDB

set -e

echo "Setting up test data..."

# Create directories
mkdir -p data/git

# Create sample predicate: created
cat > data/git/created <<'EOF'
% Artists and their works
created(tina_keane, she).
created(tina_keane, faded_wallpaper).
created(bruce_nauman, mapping_the_studio).
created(john_smith, artwork_1).
created(jane_doe, sculpture_2).
EOF

# Create sample predicate: shown_in
cat > data/git/shown_in <<'EOF'
% Exhibition facts
shown_in(she, rewind_exhibition_1995).
shown_in(faded_wallpaper, rewind_exhibition_1995).
shown_in(mapping_the_studio, tate_modern_2020).
shown_in(sculpture_2, contemporary_show_2025).
EOF

# Create sample predicate: held_at
cat > data/git/held_at <<'EOF'
held_at(rewind_exhibition_1995, ica_london).
held_at(tate_modern_2020, tate_modern).
held_at(contemporary_show_2025, saatchi_gallery).
EOF

# Create sample predicate: created_in_year
cat > data/git/created_in_year <<'EOF'
created_in_year(she, 1979).
created_in_year(faded_wallpaper, 1988).
created_in_year(mapping_the_studio, 2001).
created_in_year(artwork_1, 2015).
created_in_year(sculpture_2, 2024).
EOF

# Create sample predicate: uses_medium
cat > data/git/uses_medium <<'EOF'
uses_medium(she, video).
uses_medium(faded_wallpaper, video).
uses_medium(mapping_the_studio, video_installation).
uses_medium(artwork_1, mixed_media).
uses_medium(sculpture_2, bronze).
EOF

echo "✓ Test data created in data/git/"
echo ""
echo "Predicates created:"
ls -1 data/git/
echo ""
echo "Total facts:"
for file in data/git/*; do
  name=$(basename "$file")
  count=$(grep -v '^[%#]' "$file" | grep -v '^[[:space:]]*$' | wc -l)
  echo "  $name: $count facts"
done
