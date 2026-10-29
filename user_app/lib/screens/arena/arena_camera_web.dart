import 'package:flutter/material.dart';

import '../../data/arena_api.dart';
import '../../ui/ui.dart';

/// Web build: the camera rep counter is mobile-only.
class ArenaCameraScreen extends StatelessWidget {
  const ArenaCameraScreen({super.key, required this.exercise, this.level});

  final ArenaExercise exercise;
  final ArenaLevel? level;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('${exercise.name} · AI Arena')),
      body: EmptyView(
        icon: Icons.phone_iphone_rounded,
        title: 'Use the FITKEY mobile app for AI rep counting',
        message: 'AI Arena uses your phone camera to count every rep on-device. '
            'Leaderboards and your history work here too.',
        action: SizedBox(
          width: 200,
          child: OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Back to leaderboard')),
        ),
      ),
    );
  }
}
