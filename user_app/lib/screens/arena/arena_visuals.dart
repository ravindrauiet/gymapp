import 'package:flutter/material.dart';

import '../../ui/ui.dart';

/// Icon, colours and photo for each AI Arena exercise.
class ArenaVisual {
  const ArenaVisual(this.icon, this.color, this.soft, this.image);
  final IconData icon;
  final Color color;
  final Color soft;
  final String image;
}

ArenaVisual arenaVisual(String exerciseId) => switch (exerciseId) {
      'pushups' => const ArenaVisual(Icons.fitness_center_rounded, AppColors.primary, AppColors.primarySoft, AppImages.homeWorkout),
      'pullups' => const ArenaVisual(Icons.sports_gymnastics_rounded, AppColors.purple, AppColors.purpleSoft, AppImages.gymFloor),
      'squats' => const ArenaVisual(Icons.accessibility_new_rounded, AppColors.blue, AppColors.blueSoft, AppImages.strength),
      'plank' => const ArenaVisual(Icons.timer_rounded, AppColors.teal, AppColors.tealSoft, AppImages.yoga),
      'burpees' => const ArenaVisual(Icons.bolt_rounded, AppColors.amber, AppColors.amberSoft, AppImages.battleRopes),
      _ => const ArenaVisual(Icons.sports_score_rounded, AppColors.primary, AppColors.primarySoft, AppImages.gym),
    };
