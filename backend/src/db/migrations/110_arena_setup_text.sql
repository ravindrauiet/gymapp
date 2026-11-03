-- A flat phone's front camera only sees the ceiling: the setup step must say to stand the phone upright (portrait).
UPDATE arena_exercises SET how_to[1] = 'Stand the phone upright against a wall or bottle, at floor level, about 2 m away — in front of you or to your side. Keep your head, shoulders and arms in view.'
  WHERE id = 'pushups';
UPDATE arena_exercises SET how_to[1] = 'Stand the phone upright against a wall or bottle, 2.5–3 m away and side-on to you, with head to feet in view.'
  WHERE id IN ('plank', 'burpees');
UPDATE arena_exercises SET how_to[1] = 'Stand the phone upright at hip height, 2–3 m away and side-on or at an angle, with head to feet in view.'
  WHERE id = 'squats';
