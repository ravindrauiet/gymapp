import 'package:fitkey_core/fitkey_core.dart' show formatNumber, formatShortDate;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/events_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'leaderboard_list.dart';

/// Trophy (BRD §3.4): overall FitKey points, rank and badges across all activity.
class TrophyScreen extends StatefulWidget {
  const TrophyScreen({super.key});

  @override
  State<TrophyScreen> createState() => _TrophyScreenState();
}

class _TrophyScreenState extends State<TrophyScreen> {
  String _period = 'week';
  bool _myCity = false;
  late Future<PointsBoard> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<PointsBoard> _load() {
    final s = context.read<Session>();
    return s.api.points(period: _period, city: _myCity ? s.user?.city : null);
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* shown by the FutureBuilder */}
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final city = session.user?.city;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Trophy board')),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _reload,
        child: FutureBuilder<PointsBoard>(
          future: _future,
          builder: (context, snap) {
            final children = <Widget>[
              const SizedBox(height: 14),
              ChoiceChips<bool>(
                options: [false, if (city != null) true],
                selected: _myCity,
                label: (mine) => mine ? city! : 'All India',
                icon: (mine) => mine ? Icons.location_on_rounded : Icons.public_rounded,
                onSelected: (mine) {
                  if (mine == _myCity) return;
                  _myCity = mine;
                  _reload();
                },
              ),
              const SizedBox(height: 8),
              ChoiceChips<String>(
                options: const ['week', 'month'],
                selected: _period,
                label: (p) => p == 'week' ? 'This week' : 'This month',
                icon: (p) => p == 'week' ? Icons.date_range_rounded : Icons.calendar_month_rounded,
                onSelected: (p) {
                  if (p == _period) return;
                  _period = p;
                  _reload();
                },
              ),
            ];
            if (snap.connectionState != ConnectionState.done) {
              children.add(const SkeletonList(count: 4, itemHeight: 110));
            } else if (snap.hasError) {
              children.add(ErrorView(error: snap.error!, onRetry: _reload));
            } else {
              final b = snap.data!;
              children.addAll([
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: _MyPointsCard(board: b, period: _period),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SectionTitle('Badges', subtitle: '${b.earnedCount} earned'),
                ),
                _Badges(badges: b.badges),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SectionTitle('Leaderboard',
                      subtitle: '${b.totalRanked} ranked · ${_myCity ? city : 'All India'}'),
                ),
                if (b.entries.isEmpty)
                  const EmptyView(
                    icon: Icons.leaderboard_rounded,
                    title: 'No points on the board yet',
                    message: 'Check in, log workouts and runs, or try the AI Arena to be first on the board.',
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                    child: LeaderboardList(board: b.leaderboard, myUserId: session.user?.id, unit: 'pts', shrinkWrap: true),
                  ),
              ]);
            }
            return ListView(physics: const AlwaysScrollableScrollPhysics(), children: children);
          },
        ),
      ),
    );
  }
}

class _MyPointsCard extends StatelessWidget {
  const _MyPointsCard({required this.board, required this.period});
  final PointsBoard board;
  final String period;

  @override
  Widget build(BuildContext context) {
    final me = board.me;
    final rank = me?.rank;
    final parts = [
      (Icons.login_rounded, 'Check-in days', me?.checkinDays ?? 0, 10, AppColors.purple),
      (Icons.fitness_center_rounded, 'Workouts', me?.workouts ?? 0, 5, AppColors.primary),
      (Icons.directions_run_rounded, 'Km run', (me?.runningKm ?? 0).floor(), 1, AppColors.teal),
    ];
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFB800), Color(0xFFFF7A45)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: AppShadows.glow(const Color(0xFFFF7A45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(period == 'week' ? 'YOUR POINTS THIS WEEK' : 'YOUR POINTS THIS MONTH',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9), fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(formatNumber(me?.score ?? 0),
                  style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: -1.2)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              const Icon(Icons.emoji_events_rounded, color: Color(0xFFFFB800), size: 22),
              Text(rank == null ? '–' : '#$rank', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              Text('of ${board.totalRanked}',
                  style: const TextStyle(fontSize: 11, color: AppColors.text2, fontWeight: FontWeight.w700)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: Column(children: [
            for (final p in parts) _BreakdownRow(icon: p.$1, label: p.$2, count: p.$3, per: p.$4, color: p.$5),
            _BreakdownRow(
              icon: Icons.auto_awesome_rounded,
              label: 'AI Arena points',
              count: me?.arenaPoints ?? 0,
              per: 1,
              color: AppColors.pink,
              last: true,
            ),
          ]),
        ),
        if (rank == null) ...[
          const SizedBox(height: 10),
          Text('Train ${period == 'week' ? 'this week' : 'this month'} to get ranked.',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5)),
        ],
      ]),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.icon,
    required this.label,
    required this.count,
    required this.per,
    required this.color,
    this.last = false,
  });
  final IconData icon;
  final String label;
  final int count;
  final int per;
  final Color color;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 10),
      child: Row(children: [
        IconBubble(icon, color: color, size: 30),
        const SizedBox(width: 10),
        Expanded(
          child: Text(per == 1 ? '$label · $count' : '$label · $count × $per',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
        ),
        Text('+${count * per}', style: TextStyle(fontWeight: FontWeight.w800, color: color)),
      ]),
    );
  }
}

class _Badges extends StatelessWidget {
  const _Badges({required this.badges});
  final List<TrophyBadge> badges;

  static (IconData, Color) _style(String icon) => switch (icon) {
        'school' => (Icons.school_rounded, AppColors.purple),
        'business' => (Icons.verified_rounded, AppColors.purple),
        'login' => (Icons.login_rounded, AppColors.blue),
        'fitness' => (Icons.fitness_center_rounded, AppColors.primary),
        'fire' => (Icons.local_fire_department_rounded, AppColors.red),
        'run' => (Icons.directions_run_rounded, AppColors.teal),
        'workout' => (Icons.sports_gymnastics_rounded, AppColors.green),
        'event' => (Icons.emoji_events_rounded, AppColors.amber),
        'place' => (Icons.place_rounded, AppColors.blue),
        'arena' => (Icons.auto_awesome_rounded, AppColors.pink),
        _ => (Icons.military_tech_rounded, AppColors.amber),
      };

  @override
  Widget build(BuildContext context) {
    if (badges.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: AppCard(child: Text('Your first check-in earns your first badge.')),
      );
    }
    return SizedBox(
      height: 168,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        scrollDirection: Axis.horizontal,
        itemCount: badges.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final b = badges[i];
          final (icon, color) = _style(b.icon);
          return SizedBox(
            width: 132,
            child: AppCard(
              padding: const EdgeInsets.all(12),
              color: b.earned ? AppColors.surface : AppColors.surfaceAlt,
              shadow: b.earned,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Stack(clipBehavior: Clip.none, children: [
                  IconBubble(icon, color: b.earned ? color : AppColors.text3, size: 42),
                  if (!b.earned)
                    const Positioned(right: -4, bottom: -4, child: Icon(Icons.lock_rounded, size: 16, color: AppColors.text3)),
                ]),
                const SizedBox(height: 8),
                Text(b.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 13, color: b.earned ? AppColors.text : AppColors.text2)),
                const Spacer(),
                if (b.earned)
                  Text(b.earnedAt != null ? formatShortDate(b.earnedAt!) : b.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600))
                else ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: b.target == 0 ? 0 : b.progress / b.target,
                      minHeight: 5,
                      backgroundColor: AppColors.line,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('${b.progress}/${b.target}',
                      style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w700)),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }
}
