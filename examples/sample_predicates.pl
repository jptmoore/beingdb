% Example predicates for BeingDB
% This file demonstrates the predicate format

% Artist creation facts
created(tina_keane, she).
created(tina_keane, faded_wallpaper).
created(bruce_nauman, mapping_the_studio).

% Exhibition facts
shown_in(she, rewind_exhibition_1995).
shown_in(faded_wallpaper, rewind_exhibition_1995).
shown_in(mapping_the_studio, tate_modern_2020).

% Location facts
held_at(rewind_exhibition_1995, ica_london).
held_at(tate_modern_2020, tate_modern).

% Temporal facts
created_in_year(she, 1979).
created_in_year(faded_wallpaper, 1988).
created_in_year(mapping_the_studio, 2001).

% Medium facts
uses_medium(she, video).
uses_medium(faded_wallpaper, video).
uses_medium(mapping_the_studio, video_installation).
