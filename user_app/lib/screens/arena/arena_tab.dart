import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/arena_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'arena_exercise_screen.dart';
import 'arena_visuals.dart';
import 'proveit_share.dart';

/// ProveIt — "Only real reps count". All-India camera-verified challenges: Levels (badges, points, coins) and
/// Unlimited (All India Rank). Shown as a tab inside Community and as the full [ProveItScreen] from Home.
class ArenaTab extends StatefulWidget {
  const ArenaTab({super.key, this.query = ''});

  /// Community search text; filter challenges by it.
  final String query;

  @override
  State<ArenaTab> createState() => _ArenaTabState();
}

class _ArenaTabState extends State<ArenaTab> {
  late Future<(List<ArenaExercise>, ProveItSummary?)> _future = _load();

  Future<(List<ArenaExercise>, ProveItSummary?)> _load() async {
    final api = context.read<Session>().api;
    final summary = api.proveItSummary().then<ProveItSummary?>((s) => s).catchError((Object _) => null);
    final list = await api.arenaExercises();
    return (list, await summary);
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    await f;
  }

  Future<void> _open(ArenaExercise e, {bool unlimited = false}) async {
    await push(context, ArenaExerciseScreen(exerciseId: e.id, startUnlimited: unlimited));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _reload,
      child: FutureBuilder<(List<ArenaExercise>, ProveItSummary?)>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return ListView(physics: const AlwaysScrollableScrollPhysics(), children: const [
              Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 0), child: SkeletonBox(height: 190, radius: 22)),
              SkeletonList(count: 4, itemHeight: 124),
            ]);
          }
          if (snap.hasError) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [ErrorView(error: snap.error!, onRetry: _reload)],
            );
          }
          final (all, summary) = snap.data!;
          final q = widget.query.trim().toLowerCase();
          final list = q.isEmpty
              ? all
              : all
                  .where((e) =>
                      e.name.toLowerCase().contains(q) ||
                      e.id.contains(q) ||
                      (e.tagline ?? '').toLowerCase().contains(q) ||
                      'proveit prove it'.contains(q))
                  .toList();
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (q.isEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: _Hero(summary: summary, onStart: list.isEmpty ? null : () => _open(list.first, unlimited: true)),
                ),
                const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 0), child: _HowItWorks()),
              ],
              const SectionTitle('Challenges', subtitle: 'Levels earn badges & coins · Unlimited sets your AIR'),
              if (list.isEmpty)
                EmptyView(
                  icon: Icons.search_off_rounded,
                  title: 'No challenge matches "${widget.query.trim()}"',
                  message: 'Try pushups, squats, pullups or plank.',
                )
              else
                for (final e in list)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: _ExerciseCard(e, onTap: () => _open(e)),
                  ),
              if (q.isEmpty && summary != null) _Badges(summary: summary, exercises: all),
            ],
          );
        },
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.summary, required this.onStart});
  final ProveItSummary? summary;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final best = s?.bestRank;
    Widget stat(String value, String label) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
            Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 11.5)),
          ]),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1B25), Color(0xFF3B1D17)],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(color: AppColors.lime, borderRadius: BorderRadius.circular(8)),
              child: const Text('PROVEIT',
                  style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1.4)),
            ),
            const SizedBox(width: 8),
            Text('All India', style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontWeight: FontWeight.w700)),
            const Spacer(),
            if (best != null)
              IconButton(
                tooltip: 'Share my rank',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.ios_share_rounded, color: Colors.white),
                onPressed: () => shareProveIt(
                  context,
                  ProveItShareData(
                    exerciseId: best.exerciseId,
                    exerciseName: best.name,
                    headline: 'All India Rank',
                    value: '#${best.rank}',
                    unit: 'in India',
                    lines: [
                      if (best.best != null) 'Best ${best.best}${best.unit == 'seconds' ? ' s' : ' reps'}',
                      if (best.cityRank != null && best.city != null) '#${best.cityRank} in ${best.city}',
                    ],
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 10),
          const Text('Only real reps count',
              style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
          const SizedBox(height: 4),
          Text('Your camera counts every full rep. Clear levels for badges & coins, go Unlimited to climb the All India Rank.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13, height: 1.35)),
          const SizedBox(height: 14),
          Row(children: [
            stat(best?.rank == null ? '—' : '#${best!.rank}', best == null ? 'Your best AIR' : 'AIR · ${best.name}'),
            stat(s == null ? '—' : '${s.badges.length}/${s.badgesTotal}', 'Badges'),
            stat(s == null ? '—' : '${s.coinsEarned + s.coinsPending}', 'ProveIt coins'),
          ]),
          if (onStart != null) ...[
            const SizedBox(height: 14),
            AppButton(
              label: 'Go Unlimited',
              icon: Icons.all_inclusive_rounded,
              color: AppColors.lime,
              foreground: AppColors.ink,
              height: 48,
              onPressed: onStart,
            ),
          ],
        ]),
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
        step(Icons.videocam_rounded, AppColors.blue, AppColors.blueSoft, 'Prop your phone — AI counts full reps only'),
        step(Icons.workspace_premium_rounded, AppColors.amber, AppColors.amberSoft, 'Levels: badge + coins the first time'),
        step(Icons.leaderboard_rounded, AppColors.primary, AppColors.primarySoft, 'Unlimited: one set sets your AIR'),
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
            height: 132,
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
                if (s.myRank != null) Tag('AIR #${s.myRank}', color: v.color, bg: v.soft, dense: true),
              ]),
              const SizedBox(height: 3),
              Text(e.tagline ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.3)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final l in e.levels)
                  Tag(e.format(l.target),
                      icon: l.badge != null ? Icons.workspace_premium_rounded : null,
                      color: l.badge != null ? AppColors.amber : AppColors.text2,
                      bg: l.badge != null ? AppColors.amberSoft : AppColors.surfaceAlt,
                      dense: true),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Icon(s.myBest == null ? Icons.all_inclusive_rounded : Icons.emoji_events_outlined,
                    size: 15, color: s.myBest == null ? AppColors.primary : AppColors.amber),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    s.myBest == null
                        ? 'No Unlimited set yet'
                        : 'Best ${e.format(s.myBest!)}${s.myCityRank != null && s.myCity != null ? ' · #${s.myCityRank} ${s.myCity}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: s.myBest == null ? AppColors.primary : AppColors.text),
                  ),
                ),
                Text('${s.participants} ranked', style: const TextStyle(fontSize: 11.5, color: AppColors.text3)),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Earned badges; tap one to share it.
class _Badges extends StatelessWidget {
  const _Badges({required this.summary, required this.exercises});
  final ProveItSummary summary;
  final List<ArenaExercise> exercises;

  @override
  Widget build(BuildContext context) {
    final b = summary.badges;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionTitle('My badges',
          subtitle: summary.coinsPending > 0
              ? '${summary.coinsPending} coins are on their way to your wallet'
              : '${b.length} of ${summary.badgesTotal} earned · tap to share'),
      if (b.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: AppCard(
            child: Row(children: [
              IconBubble(Icons.workspace_premium_rounded, color: AppColors.amber, bg: AppColors.amberSoft),
              SizedBox(width: 12),
              Expanded(
                child: Text('Complete any level to earn your first badge and 10–50 ProveIt coins.',
                    style: TextStyle(color: AppColors.text2, height: 1.35)),
              ),
            ]),
          ),
        )
      else
        SizedBox(
          height: 128,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: b.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final x = b[i];
              final v = arenaVisual(x.exerciseId);
              return AppCard(
                padding: const EdgeInsets.all(12),
                onTap: () => shareProveIt(
                  context,
                  ProveItShareData(
                    exerciseId: x.exerciseId,
                    exerciseName: x.name,
                    headline: 'Level ${x.level} complete',
                    value: '${x.target}',
                    unit: x.unit == 'seconds' ? 'seconds' : 'reps',
                    lines: ['ProveIt badge', if (x.coins > 0) '+${x.coins} coins'],
                  ),
                ),
                child: SizedBox(
                  width: 96,
                  child: Column(children: [
                    Stack(clipBehavior: Clip.none, children: [
                      IconBubble(v.icon, color: v.color, bg: v.soft, size: 46),
                      const Positioned(
                        right: -6,
                        bottom: -4,
                        child: Icon(Icons.workspace_premium_rounded, color: AppColors.amber, size: 22),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Text(x.name, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                    Text('L${x.level} · ${x.targetLabel}', style: const TextStyle(color: AppColors.text2, fontSize: 11.5)),
                  ]),
                ),
              );
            },
          ),
        ),
    ]);
  }
}
