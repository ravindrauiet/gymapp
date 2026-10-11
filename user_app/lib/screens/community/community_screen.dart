import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import 'buddy_screens.dart';
import 'contest_detail_screen.dart';

/// Community hub: Gym buddy (U6), Contests (U7) and Leaderboard (U8).
class CommunityScreen extends StatelessWidget {
  const CommunityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Community'),
          bottom: const TabBar(tabs: [Tab(text: 'Gym buddy'), Tab(text: 'Contests'), Tab(text: 'Leaderboard')]),
        ),
        body: const TabBarView(children: [BuddyTab(), _ContestsTab(), _LeaderboardTab()]),
      ),
    );
  }
}

class _ContestsTab extends StatefulWidget {
  const _ContestsTab();

  @override
  State<_ContestsTab> createState() => _ContestsTabState();
}

class _ContestsTabState extends State<_ContestsTab> {
  String _status = 'active';
  late Future<List<Contest>> _future = _load();

  Future<List<Contest>> _load() => context.read<Session>().api.contests(status: _status);

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'active', label: Text('Live')),
            ButtonSegment(value: 'upcoming', label: Text('Upcoming')),
            ButtonSegment(value: 'past', label: Text('Past')),
          ],
          selected: {_status},
          onSelectionChanged: (s) {
            _status = s.first;
            _reload();
          },
        ),
      ),
      Expanded(
        child: AsyncView<List<Contest>>(
          future: _future,
          onRetry: _reload,
          builder: (context, contests) => contests.isEmpty
              ? const EmptyState(icon: Icons.emoji_events_outlined, title: 'No contests here yet')
              : RefreshIndicator(
                  onRefresh: () async {
                    _reload();
                    await _future;
                  },
                  child: ListView.separated(
                    padding: const EdgeInsets.all(20),
                    itemCount: contests.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => _ContestTile(
                      contest: contests[i],
                      onTap: () async {
                        await Navigator.push(context,
                            MaterialPageRoute(builder: (_) => ContestDetailScreen(contestId: contests[i].id)));
                        _reload();
                      },
                    ),
                  ),
                ),
        ),
      ),
    ]);
  }
}

class _ContestTile extends StatelessWidget {
  const _ContestTile({required this.contest, required this.onTap});

  final Contest contest;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = switch (contest.metric) {
      'running_km' => Icons.directions_run,
      'streak' => Icons.local_fire_department,
      _ => Icons.login,
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: FkColors.orange.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: FkColors.orange),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(contest.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('${formatShortDate(contest.startsOn)} – ${formatShortDate(contest.endsOn)} · ${contest.participantCount} players',
                    style: const TextStyle(color: FkColors.textSecondary, fontSize: 12)),
                if (contest.reward != null) ...[
                  const SizedBox(height: 6),
                  Row(children: [
                    const Icon(Icons.card_giftcard, size: 14, color: Color(0xFFFFC145)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(contest.reward!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Color(0xFFFFC145))),
                    ),
                  ]),
                ],
              ]),
            ),
            if (contest.joined) const Icon(Icons.check_circle, color: FkColors.lime),
          ]),
        ),
      ),
    );
  }
}

class _LeaderboardTab extends StatefulWidget {
  const _LeaderboardTab();

  @override
  State<_LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends State<_LeaderboardTab> {
  String _period = 'weekly';
  bool _myCity = false;
  late Future<Leaderboard> _future = _load();

  Future<Leaderboard> _load() {
    final session = context.read<Session>();
    return session.api.leaderboard(period: _period, city: _myCity ? session.user?.city : null);
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        child: Row(children: [
          Expanded(
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'weekly', label: Text('This week')),
                ButtonSegment(value: 'monthly', label: Text('This month')),
              ],
              selected: {_period},
              onSelectionChanged: (s) {
                _period = s.first;
                _reload();
              },
            ),
          ),
        ]),
      ),
      if (session.user?.city != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            FilterChip(
              selected: !_myCity,
              label: Text('All India', style: TextStyle(color: !_myCity ? Colors.black : null)),
              onSelected: (_) {
                _myCity = false;
                _reload();
              },
            ),
            const SizedBox(width: 8),
            FilterChip(
              selected: _myCity,
              label: Text(session.user!.city!, style: TextStyle(color: _myCity ? Colors.black : null)),
              onSelected: (_) {
                _myCity = true;
                _reload();
              },
            ),
          ]),
        ),
      Expanded(
        child: AsyncView<Leaderboard>(
          future: _future,
          onRetry: _reload,
          builder: (context, board) => board.entries.isEmpty
              ? const EmptyState(
                  icon: Icons.leaderboard_outlined,
                  title: 'No points yet',
                  message: 'Check in and log workouts to climb the board.',
                )
              : LeaderboardList(board: board, myUserId: session.user?.id, unit: 'pts'),
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Text('10 pts per check-in day · 5 pts per workout logged · 1 pt per km run',
            style: TextStyle(fontSize: 11, color: FkColors.textSecondary)),
      ),
    ]);
  }
}

/// Ranked list with medals for the top 3 and the current user's row pinned at the bottom.
class LeaderboardList extends StatelessWidget {
  const LeaderboardList({super.key, required this.board, required this.myUserId, required this.unit, this.shrinkWrap = false});

  final Leaderboard board;
  final String? myUserId;
  final String unit;
  final bool shrinkWrap;

  static const _medals = [Color(0xFFFFC145), Color(0xFFC0C7D0), Color(0xFFCD8B5A)];

  @override
  Widget build(BuildContext context) {
    final me = board.me;
    final meVisible = me != null && board.entries.take(20).any((e) => e.userId == me.userId);
    final list = ListView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      itemCount: board.entries.length,
      itemBuilder: (_, i) => _row(board.entries[i]),
    );
    if (shrinkWrap || me == null || meVisible) return list;
    return Column(children: [
      Expanded(child: list),
      Container(
        color: FkColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: _row(me),
      ),
    ]);
  }

  Widget _row(LeaderEntry e) {
    final isMe = e.userId == myUserId;
    final medal = e.rank <= 3 ? _medals[e.rank - 1] : null;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isMe ? FkColors.lime.withValues(alpha: 0.12) : FkColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isMe ? FkColors.lime.withValues(alpha: 0.5) : FkColors.outline),
      ),
      child: Row(children: [
        SizedBox(
          width: 32,
          child: medal != null
              ? Icon(Icons.emoji_events, color: medal)
              : Text('#${e.rank}', style: const TextStyle(fontWeight: FontWeight.w700, color: FkColors.textSecondary)),
        ),
        const SizedBox(width: 8),
        Avatar(name: e.name, radius: 18, color: medal ?? FkColors.lime),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isMe ? '${e.name ?? 'You'} (you)' : e.name ?? 'FITKEY member',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (e.city != null) Text(e.city!, style: const TextStyle(fontSize: 12, color: FkColors.textSecondary)),
          ]),
        ),
        Text('${formatNumber(e.score)} $unit', style: const TextStyle(fontWeight: FontWeight.w800)),
      ]),
    );
  }
}
