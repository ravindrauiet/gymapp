import 'package:flutter/material.dart';

import 'theme.dart';

/// Bundled photography (Unsplash licence, free for commercial use). See assets/CREDITS.md.
class AppImages {
  static const _p = 'assets/images';
  static const gym = '$_p/gym.jpg';
  static const gymFloor = '$_p/gym_floor.jpg';
  static const strength = '$_p/strength.jpg';
  static const swimming = '$_p/swimming.jpg';
  static const yoga = '$_p/yoga.jpg';
  static const sports = '$_p/sports.jpg';
  static const boxing = '$_p/boxing.jpg';
  static const martialArts = '$_p/martial_arts.jpg';
  static const dance = '$_p/dance.jpg';
  static const foodBowl = '$_p/food_bowl.jpg';
  static const foodPlate = '$_p/food_plate.jpg';
  static const homeWorkout = '$_p/home_workout.jpg';
  static const running = '$_p/running.jpg';
  static const supplements = '$_p/supplements.jpg';
  static const groupClass = '$_p/group_class.jpg';
  static const battleRopes = '$_p/battle_ropes.jpg';
  static const onboarding = '$_p/onboarding.jpg';
}

/// How a venue / video / activity category looks in the member app.
class CatVisual {
  const CatVisual(this.label, this.icon, this.color, this.soft, this.image);
  final String label;
  final IconData icon;
  final Color color;
  final Color soft;
  final String image;
}

const _venueVisuals = <String, CatVisual>{
  'gym': CatVisual('Gym', Icons.fitness_center_rounded, AppColors.primary, AppColors.primarySoft, AppImages.gym),
  'swimming_pool': CatVisual('Swimming', Icons.pool_rounded, AppColors.blue, AppColors.blueSoft, AppImages.swimming),
  'sports_club': CatVisual('Sports', Icons.sports_tennis_rounded, AppColors.green, AppColors.greenSoft, AppImages.sports),
  'yoga_studio': CatVisual('Yoga', Icons.self_improvement_rounded, AppColors.purple, AppColors.purpleSoft, AppImages.yoga),
  'mma': CatVisual('MMA', Icons.sports_mma_rounded, AppColors.red, AppColors.redSoft, AppImages.boxing),
  'martial_arts':
      CatVisual('Martial Arts', Icons.sports_kabaddi_rounded, AppColors.amber, AppColors.amberSoft, AppImages.martialArts),
  'dance': CatVisual('Dance', Icons.music_note_rounded, AppColors.pink, AppColors.pinkSoft, AppImages.dance),
};

const _videoVisuals = <String, CatVisual>{
  'gym': CatVisual('Gym', Icons.fitness_center_rounded, AppColors.primary, AppColors.primarySoft, AppImages.strength),
  'yoga': CatVisual('Yoga', Icons.self_improvement_rounded, AppColors.purple, AppColors.purpleSoft, AppImages.yoga),
  'dance': CatVisual('Dance / Zumba', Icons.music_note_rounded, AppColors.pink, AppColors.pinkSoft, AppImages.dance),
  'boxing': CatVisual('Boxing', Icons.sports_mma_rounded, AppColors.red, AppColors.redSoft, AppImages.boxing),
  'martial_arts':
      CatVisual('Judo / Karate', Icons.sports_kabaddi_rounded, AppColors.amber, AppColors.amberSoft, AppImages.martialArts),
};

const _activityVisuals = <String, CatVisual>{
  'workout': CatVisual('Workout', Icons.fitness_center_rounded, AppColors.primary, AppColors.primarySoft, AppImages.strength),
  'running': CatVisual('Running', Icons.directions_run_rounded, AppColors.amber, AppColors.amberSoft, AppImages.running),
  'cycling': CatVisual('Cycling', Icons.directions_bike_rounded, AppColors.blue, AppColors.blueSoft, AppImages.running),
  'swimming': CatVisual('Swimming', Icons.pool_rounded, AppColors.blue, AppColors.blueSoft, AppImages.swimming),
  'yoga': CatVisual('Yoga', Icons.self_improvement_rounded, AppColors.purple, AppColors.purpleSoft, AppImages.yoga),
  'sports': CatVisual('Sports', Icons.sports_tennis_rounded, AppColors.green, AppColors.greenSoft, AppImages.sports),
  'other': CatVisual('Other', Icons.bolt_rounded, AppColors.text2, AppColors.surfaceAlt, AppImages.battleRopes),
};

CatVisual venueVisual(String id) =>
    _venueVisuals[id] ??
    CatVisual(id, Icons.place_rounded, AppColors.text2, AppColors.surfaceAlt, AppImages.gymFloor);
CatVisual videoVisual(String id) =>
    _videoVisuals[id] ??
    CatVisual(id, Icons.play_circle_rounded, AppColors.text2, AppColors.surfaceAlt, AppImages.groupClass);
CatVisual activityVisual(String id) => _activityVisuals[id] ?? _activityVisuals['other']!;

Iterable<MapEntry<String, CatVisual>> get venueVisuals => _venueVisuals.entries;
Iterable<MapEntry<String, CatVisual>> get videoVisuals => _videoVisuals.entries;
Iterable<MapEntry<String, CatVisual>> get activityVisuals => _activityVisuals.entries;

/// Image for a store product category when a product has no photo.
String productFallbackImage(String category) => switch (category) {
      'supplements' => AppImages.supplements,
      'apparel' => AppImages.running,
      'wearables' => AppImages.running,
      _ => AppImages.homeWorkout,
    };
