import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/arena_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'arena_exercise_screen.dart';
import 'arena_visuals.dart';

/// AI Arena — always-on all-India exercise challenges. Shown as a tab inside Community.
class ArenaTab extends StatefulWidget {
  const ArenaTab({super.key, this.query = ''});

  /// Community search text; filter exercises by it.
  final String query;

  @override
  State<ArenaTab> createState() => _ArenaTabState();
}

class _ArenaTabState extends State<ArenaTab> {
  late Future<List<ArenaExercise>> _future = _load();

  Future<List<ArenaExercise>> _load() => context.read<Session>().api.arenaExercises();

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    await f;
  }

  Future<void> _open(ArenaExercise e) async {
    await push(context, ArenaExerciseScreen(exerciseId: e.id));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _reload,
      child: FutureBuilder<List<ArenaExercise>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return ListView(physics: const AlwaysScrollableScrollPhysics(), children: const [
              Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 0), child: SkeletonBox(height: 170, radius: 22)),
              SkeletonList(count: 4, itemHeight: 112),
            ]);
          }
          if (snap.hasError) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [ErrorView(error: snap.error!, onRetry: _reload)],
            );
          }
          final all = snap.data!;
          final q = widget.query.trim().toLowerCase();
          final list = q.isEmpty
              ? all
              : all
                  .where((e) =>
                      e.name.toLowerCase().contains(q) ||
                      e.id.contains(q) ||
                      (e.tagline ?? '').toLowerCase().contains(q) ||
                      'ai arena'.contains(q))
                  .toList();
          final pointsToday = all.fold<int>(0, (s, e) => s + e.stats.pointsToday);
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (q.isEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: PhotoBanner(
                    image: AppImages.homeWorkout,
                    eyebrow: 'AI Arena · All India',
                    title: 'Your camera counts every rep',
                    subtitle: 'Pick a challenge, hit the level, climb the national leaderboard.',
                    cta: list.isEmpty ? null : 'Start with ${list.first.name}',
                    onTap: list.isEmpty ? null : () => _open(list.first),
                  ),
                ),
                const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 0), child: _HowItWorks()),
                if (pointsToday > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: AppCard(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      color: AppColors.greenSoft,
                      shadow: false,
                      child: Row(children: [
                        const Icon(Icons.stars_rounded, color: AppColors.green),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text('+$pointsToday Arena points earned today',
                              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.green)),
                        ),
                      ]),
                    ),
                  ),
              ],
              SectionTitle('Challenges', subtitle: 'Full-range reps only — the AI checks your form'),
              if (list.isEmpty)
                EmptyView(
                  icon: Icons.search_off_rounded,
                  title: 'No challenge matches "${widget.query.trim()}"',
                  message: 'Try pushups, pullups, squats, plank or burpees.',
                )
              else
                for (final e in list)
                  Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: _ExerciseCard(e, onTap: () => _open(e))),
            ],
          );
        },
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    Widget step(IconData icon, Color c, Color soft, String t) => Expanded(
          child: Column(children: [
            IconBubble(icon, color: c, bg: soft, size: 40, iconSize: 20),
            const SizedBox(height: 6),
            Text(t,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.text2, height: 1.3)),
          ]),
        );
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        step(Icons.touch_app_rounded, AppColors.primary, AppColors.primarySoft, 'Pick an exercise & level'),
        step(Icons.videocam_rounded, AppColors.blue, AppColors.blueSoft, 'Prop your phone, AI counts reps'),
        step(Icons.leaderboard_rounded, AppColors.amber, AppColors.amberSoft, 'Earn points & rank in India'),
      ]),
    );
  }
}

class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard(this.e, {required this.onTap});
  final ArenaExercise e;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = arenaVisual(e.id);
    final s = e.stats;
    return AppCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Row(children: [
        ClipRRect(
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(20)),
          child: SizedBox(
            width: 104,
            height: 124,
            child: Stack(fit: StackFit.expand, children: [
              Image.asset(v.image, fit: BoxFit.cover),
              DecoratedBox(decoration: BoxDecoration(color: v.color.withValues(alpha: 0.25))),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  child: Icon(v.icon, color: v.color, size: 24),
                ),
              ),
            ]),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(e.name, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
                ),
                if (s.myRank != null) Tag('#${s.myRank} India', color: v.color, bg: v.soft, dense: true),
              ]),
              const SizedBox(height: 3),
              Text(e.tagline ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.3)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final l in e.levels) Tag(e.format(l.target), color: AppColors.text2, bg: AppColors.surfaceAlt, dense: true),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Icon(s.myBest == null ? Icons.play_circle_outline_rounded : Icons.emoji_events_outlined,
                    size: 15, color: s.myBest == null ? AppColors.primary : AppColors.amber),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    s.myBest == null ? 'No set yet — be on the board' : 'Best ${e.format(s.myBest!)}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: s.myBest == null ? AppColors.primary : AppColors.text),
                  ),
                ),
                Text('${s.participants} on board', style: const TextStyle(fontSize: 11.5, color: AppColors.text3)),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}
