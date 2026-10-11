import 'package:flutter/material.dart';

import 'theme.dart';

class CategoryStyle {
  const CategoryStyle(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

const venueCategories = <String, CategoryStyle>{
  'gym': CategoryStyle('Gym', Icons.fitness_center, FkColors.lime),
  'swimming_pool': CategoryStyle('Swimming', Icons.pool, FkColors.sky),
  'sports_club': CategoryStyle('Sports', Icons.sports_tennis, FkColors.orange),
  'yoga_studio': CategoryStyle('Yoga', Icons.self_improvement, FkColors.violet),
  'mma': CategoryStyle('MMA', Icons.sports_mma, FkColors.danger),
  'martial_arts': CategoryStyle('Martial Arts', Icons.sports_kabaddi, Color(0xFFFFC145)),
  'dance': CategoryStyle('Dance', Icons.music_note, Color(0xFFFF77C8)),
};

const videoCategories = <String, CategoryStyle>{
  'gym': CategoryStyle('Gym', Icons.fitness_center, FkColors.lime),
  'yoga': CategoryStyle('Yoga', Icons.self_improvement, FkColors.violet),
  'dance': CategoryStyle('Dance / Zumba', Icons.music_note, Color(0xFFFF77C8)),
  'boxing': CategoryStyle('Boxing', Icons.sports_mma, FkColors.danger),
  'martial_arts': CategoryStyle('Judo / Karate', Icons.sports_kabaddi, Color(0xFFFFC145)),
};

const activityTypes = <String, CategoryStyle>{
  'workout': CategoryStyle('Workout', Icons.fitness_center, FkColors.lime),
  'running': CategoryStyle('Running', Icons.directions_run, FkColors.orange),
  'cycling': CategoryStyle('Cycling', Icons.directions_bike, FkColors.sky),
  'swimming': CategoryStyle('Swimming', Icons.pool, FkColors.sky),
  'yoga': CategoryStyle('Yoga', Icons.self_improvement, FkColors.violet),
  'sports': CategoryStyle('Sports', Icons.sports_tennis, Color(0xFFFFC145)),
  'other': CategoryStyle('Other', Icons.bolt, FkColors.textSecondary),
};

const amenityLabels = <String, (String, IconData)>{
  'locker': ('Locker', Icons.lock_outline),
  'shower': ('Shower', Icons.shower_outlined),
  'parking': ('Parking', Icons.local_parking),
  'ac': ('AC', Icons.ac_unit),
  'wifi': ('Wi-Fi', Icons.wifi),
  'changing_room': ('Changing room', Icons.checkroom),
  'drinking_water': ('Drinking water', Icons.water_drop_outlined),
  'cafe': ('Café', Icons.local_cafe_outlined),
  'steam_sauna': ('Steam / Sauna', Icons.hot_tub_outlined),
};

CategoryStyle venueCategory(String id) =>
    venueCategories[id] ?? CategoryStyle(id, Icons.place_outlined, FkColors.textSecondary);
CategoryStyle videoCategory(String id) =>
    videoCategories[id] ?? CategoryStyle(id, Icons.play_circle_outline, FkColors.textSecondary);
CategoryStyle activityType(String id) => activityTypes[id] ?? activityTypes['other']!;
