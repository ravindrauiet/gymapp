import 'package:fitkey_core/fitkey_core.dart' show formatShortDate, formatNumber;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'buddy_screens.dart';
import 'contest_detail_screen.dart';

/// Community hub: Challenges (U7), Leaderboard (U8) and Gym buddy (U6).
/// Lives inside HomeShell as a bottom-nav tab, so there is no back button.
class CommunityScreen extends StatelessWidget {
  const CommunityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: Column(children: [
          const _Header(),
          const Expanded(child: TabBarView(children: [_ChallengesTab(), _LeaderboardTab(), BuddyTab()])),
        ]),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        boxShadow: [BoxShadow(color: Color(0x0A1A1B25), blurRadius: 12, offset: Offset(0, 4))],
      ),
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Community', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.9, height: 1.1)),
              SizedBox(height: 4),
              Text('Compete, climb the board & find a workout buddy',
                  style: TextStyle(fontSize: 13, color: AppColors.text2, fontWeight: FontWeight.w500)),
            ]),
          ),
          SizedBox(width: 12),
          IconBubble(Icons.emoji_events_rounded, color: AppColors.amber, size: 46),
        ]),
        const SizedBox(height: 16),
        Container(
          height: 46,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
          child: TabBar(
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            indicator: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(11),
              boxShadow: AppShadows.soft,
            ),
            labelColor: AppColors.text,
            unselectedLabelColor: AppColors.text2,
            labelStyle: const TextStyle(fontFamily: kFont, fontWeight: FontWeight.w800, fontSize: 13.5),
            unselectedLabelStyle: const TextStyle(fontFamily: kFont, fontWeight: FontWeight.w600, fontSize: 13.5),
            labelPadding: EdgeInsets.zero,
            splashFactory: NoSplash.splashFactory,
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            tabs: const [Tab(text: 'Challenges'), Tab(text: 'Leaderboard'), Tab(text: 'Gym Buddy')],
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared contest styling (also used by the contest detail screen)
// ---------------------------------------------------------------------------

/// Gradient + icon for a contest, keyed on what it measures so list and detail match.
({List<Color> colors, IconData icon, String metricLabel}) contestStyle(Contest c) => switch (c.metric) {
      'running_km' => (
          colors: const [Color(0xFF14B8A6), Color(0xFF0E9F6E)],
          icon: Icons.directions_run_rounded,
          metricLabel: 'Running',
        ),
      'streak' => (
          colors: const [Color(0xFFFF7A45), Color(0xFFFF4B2B)],
          icon: Icons.local_fire_department_rounded,
          metricLabel: 'Streak',
        ),
      _ => (
          colors: const [Color(0xFF7C5CFF), Color(0xFF4F46E5)],
          icon: Icons.login_rounded,
          metricLabel: 'Check-ins',
        ),
    };

/// "4d left", "Starts 2 Nov" or "Ended" depending on where today falls in the contest window.
String contestTimeLabel(Contest c) {
  final today = DateUtils.dateOnly(DateTime.now());
  if (today.isBefore(DateUtils.dateOnly(c.startsOn))) return 'Starts ${formatShortDate(c.startsOn)}';
  if (today.isAfter(DateUtils.dateOnly(c.endsOn))) return 'Ended';
  final d = c.daysLeft;
  return d <= 1 ? 'Last day' : '${d}d left';
}

bool contestFinished(Contest c) => DateUtils.dateOnly(DateTime.now()).isAfter(DateUtils.dateOnly(c.endsOn));

// ---------------------------------------------------------------------------
// Challenges
// ---------------------------------------------------------------------------

class _ChallengesTab extends StatefulWidget {
  const _ChallengesTab();

  @override
  State<_ChallengesTab> createState() => _ChallengesTabState();
}

class _ChallengesTabState extends State<_ChallengesTab> with AutomaticKeepAliveClientMixin {
  static const _statuses = ['active', 'upcoming', 'past'];
  String _status = 'active';
  late Future<List<Contest>> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Contest>> _load() => context.read<Session>().api.contests(status: _status);

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* shown by the FutureBuilder */}
  }

  Future<void> _open(Contest c) async {
    await push(context, ContestDetailScreen(contestId: c.id));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 32),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: PhotoBanner(
              image: AppImages.running,
              eyebrow: 'FitKey challenges',
              title: 'Sweat with your city. Win real rewards.',
              subtitle: 'Join free, check in & log workouts to climb.',
              height: 150,
            ),
          ),
          const SizedBox(height: 18),
          ChoiceChips<String>(
            options: _statuses,
            selected: _status,
            label: (s) => switch (s) { 'active' => 'Live now', 'upcoming' => 'Upcoming', _ => 'Past' },
            icon: (s) => switch (s) {
              'active' => Icons.bolt_rounded,
              'upcoming' => Icons.event_rounded,
              _ => Icons.history_rounded,
            },
            onSelected: (s) {
              if (s == _status) return;
              _status = s;
              _reload();
            },
          ),
          const SizedBox(height: 16),
          FutureBuilder<List<Contest>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const _CardsSkeleton();
              if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
              final contests = snap.data!;
              if (contests.isEmpty) {
                return EmptyView(
                  icon: Icons.emoji_events_rounded,
                  color: AppColors.amber,
                  title: switch (_status) {
                    'active' => 'No live challenges right now',
                    'upcoming' => 'Nothing scheduled yet',
                    _ => 'No past challenges',
                  },
                  message: _status == 'past'
                      ? 'Finished challenges and their winners will show up here.'
                      : 'New challenges drop regularly. Keep checking in so you are ready to climb.',
                  action: _status == 'active'
                      ? SizedBox(
                          width: 200,
                          child: OutlinedButton(
                            onPressed: () {
                              _status = 'upcoming';
                              _reload();
                            },
                            child: const Text('See upcoming'),
                          ),
                        )
                      : null,
                );
              }
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [
                  for (final c in contests) ...[
                    _ChallengeCard(contest: c, onTap: () => _open(c)),
                    const SizedBox(height: 14),
                  ],
                ]),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ChallengeCard extends StatelessWidget {
  const _ChallengeCard({required this.contest, required this.onTap});
  final Contest contest;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = contest;
    final s = contestStyle(c);
    final g = s.colors;
    final finished = contestFinished(c);
    const onGlass = Color(0x33FFFFFF);
    return Tap(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: g, begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(22),
          boxShadow: finished ? AppShadows.card : AppShadows.glow(g.last),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(
            right: -24,
            top: -20,
            child: Icon(s.icon, size: 120, color: Colors.white.withValues(alpha: 0.13)),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              Tag(c.period.toUpperCase(), color: Colors.white, bg: onGlass, dense: true),
              Tag(contestTimeLabel(c), icon: Icons.schedule_rounded, color: Colors.white, bg: onGlass, dense: true),
              Tag(s.metricLabel, icon: s.icon, color: Colors.white, bg: onGlass, dense: true),
            ]),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.only(right: 40),
              child: Text(c.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, height: 1.2, letterSpacing: -0.4)),
            ),
            if (c.description != null && c.description!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(c.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.82), fontSize: 13, height: 1.35)),
            ],
            if (c.reward != null && c.reward!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.card_giftcard_rounded, color: Color(0xFFFFD66B), size: 16),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(c.reward!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 16),
            Row(children: [
              const Icon(Icons.groups_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${c.participantCount} joined · ${formatShortDate(c.startsOn)} – ${formatShortDate(c.endsOn)}'
                  '${c.city != null ? ' · ${c.city}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(11)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (c.joined) ...[Icon(Icons.check_circle_rounded, size: 15, color: g.last), const SizedBox(width: 4)],
                  Text(
                    c.joined ? 'Joined' : (finished ? 'Results' : 'Join'),
                    style: TextStyle(color: g.last, fontWeight: FontWeight.w800, fontSize: 12.5),
                  ),
                ]),
              ),
            ]),
          ]),
        ]),
      ),
    );
  }
}

class _CardsSkeleton extends StatelessWidget {
  const _CardsSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: [
          SkeletonBox(height: 190, radius: 22),
          SizedBox(height: 14),
          SkeletonBox(height: 190, radius: 22),
          SizedBox(height: 14),
          SkeletonBox(height: 190, radius: 22),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Leaderboard
// ---------------------------------------------------------------------------

class _LeaderboardTab extends StatefulWidget {
  const _LeaderboardTab();

  @override
  State<_LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends State<_LeaderboardTab> with AutomaticKeepAliveClientMixin {
  String _period = 'weekly';
  bool _myCity = false;
  late Future<Leaderboard> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Leaderboard> _load() {
    final session = context.read<Session>();
    return session.api.leaderboard(period: _period, city: _myCity ? session.user?.city : null);
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
    super.build(context);
    final session = context.watch<Session>();
    final city = session.user?.city;
    return Column(children: [
      const SizedBox(height: 14),
      ChoiceChips<String>(
        options: const ['weekly', 'monthly'],
        selected: _period,
        label: (p) => p == 'weekly' ? 'This week' : 'This month',
        icon: (p) => p == 'weekly' ? Icons.date_range_rounded : Icons.calendar_month_rounded,
        onSelected: (p) {
          if (p == _period) return;
          _period = p;
          _reload();
        },
      ),
      if (city != null) ...[
        const SizedBox(height: 10),
        ChoiceChips<bool>(
          options: const [false, true],
          selected: _myCity,
          label: (mine) => mine ? city : 'All India',
          icon: (mine) => mine ? Icons.location_on_rounded : Icons.public_rounded,
          onSelected: (mine) {
            if (mine == _myCity) return;
            _myCity = mine;
            _reload();
          },
        ),
      ],
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, size: 15, color: AppColors.text3),
          SizedBox(width: 6),
          Expanded(
            child: Text('10 pts per check-in day · 5 pts per workout · 1 pt per km run',
                style: TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          color: AppColors.primary,
          onRefresh: _reload,
          child: FutureBuilder<Leaderboard>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return ListView(physics: const AlwaysScrollableScrollPhysics(), children: const [_BoardSkeleton()]);
              }
              if (snap.hasError) {
                return ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [ErrorView(error: snap.error!, onRetry: _reload)],
                );
              }
              final board = snap.data!;
              if (board.entries.isEmpty) {
                return ListView(physics: const AlwaysScrollableScrollPhysics(), children: const [
                  EmptyView(
                    icon: Icons.leaderboard_rounded,
                    title: 'No points on the board yet',
                    message: 'Check in at any FITKEY venue and log workouts to be the first on the board.',
                  ),
                ]);
              }
              return LeaderboardList(board: board, myUserId: session.user?.id, unit: 'pts');
            },
          ),
        ),
      ),
    ]);
  }
}

class _BoardSkeleton extends StatelessWidget {
  const _BoardSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(children: [
          SkeletonBox(height: 210, radius: 22),
          SizedBox(height: 14),
          SkeletonBox(height: 64, radius: 16),
          SizedBox(height: 10),
          SkeletonBox(height: 64, radius: 16),
          SizedBox(height: 10),
          SkeletonBox(height: 64, radius: 16),
        ]),
      ),
    );
  }
}

/// Top-3 podium followed by the ranked list. The current member's row is highlighted,
/// and pinned to the bottom when they are not in the visible ranking.
///
/// With [shrinkWrap] it renders as a plain column for embedding in another scroll view.
class LeaderboardList extends StatelessWidget {
  const LeaderboardList({super.key, required this.board, required this.myUserId, required this.unit, this.shrinkWrap = false});

  final Leaderboard board;
  final String? myUserId;
  final String unit;
  final bool shrinkWrap;

  static const _medals = [Color(0xFFFFB800), Color(0xFFA9B2BF), Color(0xFFCD7F4A)];

  @override
  Widget build(BuildContext context) {
    final entries = board.entries;
    final me = board.me ?? entries.where((e) => e.userId == myUserId).firstOrNull;
    final meListed = me != null && entries.any((e) => e.userId == me.userId);
    final podium = entries.take(3).toList();
    final rest = entries.skip(podium.length).toList();

    final children = <Widget>[
      if (podium.isNotEmpty) _Podium(entries: podium, myUserId: myUserId, unit: unit, medals: _medals),
      if (rest.isNotEmpty) const SizedBox(height: 14),
      for (final e in rest) ...[
        _LeaderRow(entry: e, isMe: e.userId == myUserId, unit: unit),
        const SizedBox(height: 8),
      ],
    ];

    if (shrinkWrap) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...children,
        if (me != null && !meListed) ...[
          const SizedBox(height: 6),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('YOUR POSITION',
                style: TextStyle(fontSize: 11.5, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: AppColors.text3)),
          ),
          _LeaderRow(entry: me, isMe: true, unit: unit),
        ],
      ]);
    }

    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: children,
    );
    if (me == null || meListed) return list;
    return Column(children: [
      Expanded(child: list),
      Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          boxShadow: [BoxShadow(color: Color(0x141A1B25), blurRadius: 16, offset: Offset(0, -4))],
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: _LeaderRow(entry: me, isMe: true, unit: unit, flat: true),
      ),
    ]);
  }
}

class _Podium extends StatelessWidget {
  const _Podium({required this.entries, required this.myUserId, required this.unit, required this.medals});
  final List<LeaderEntry> entries;
  final String? myUserId;
  final String unit;
  final List<Color> medals;

  @override
  Widget build(BuildContext context) {
    // Display order: 2nd, 1st, 3rd.
    final order = <int>[if (entries.length > 1) 1, 0, if (entries.length > 2) 2];
    const heights = [96.0, 68.0, 50.0];
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
      radius: 22,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final i in order)
            Expanded(
              child: _PodiumSpot(
                entry: entries[i],
                place: i + 1,
                color: medals[i],
                pedestal: heights[i],
                isMe: entries[i].userId == myUserId,
                unit: unit,
              ),
            ),
        ],
      ),
    );
  }
}

class _PodiumSpot extends StatelessWidget {
  const _PodiumSpot({
    required this.entry,
    required this.place,
    required this.color,
    required this.pedestal,
    required this.isMe,
    required this.unit,
  });
  final LeaderEntry entry;
  final int place;
  final Color color;
  final double pedestal;
  final bool isMe;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final first = place == 1;
    final size = first ? 72.0 : 58.0;
    final name = isMe ? 'You' : (entry.name ?? 'Member').split(' ').first;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (first) const Icon(Icons.workspace_premium_rounded, color: Color(0xFFFFB800), size: 26),
        SizedBox(
          width: size + 10,
          height: size + 18,
          child: Stack(alignment: Alignment.topCenter, children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [color, color.withValues(alpha: 0.55)]),
                boxShadow: AppShadows.glow(color),
              ),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(color: AppColors.surface, shape: BoxShape.circle),
                child: PersonAvatar(name: entry.name, size: size - 6),
              ),
            ),
            Positioned(
              bottom: 0,
              child: Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.surface, width: 2),
                ),
                child: Text('$place', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 6),
        Text(name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w800, color: isMe ? AppColors.primary : AppColors.text)),
        Text('${formatNumber(entry.score)} $unit',
            maxLines: 1,
            style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Container(
          height: pedestal,
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [color.withValues(alpha: 0.30), color.withValues(alpha: 0.08)],
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          ),
          alignment: Alignment.topCenter,
          padding: const EdgeInsets.only(top: 8),
          child: Text('#$place',
              style: TextStyle(fontSize: first ? 22 : 18, fontWeight: FontWeight.w800, color: color, letterSpacing: -0.5)),
        ),
      ]),
    );
  }
}

class _LeaderRow extends StatelessWidget {
  const _LeaderRow({required this.entry, required this.isMe, required this.unit, this.flat = false});
  final LeaderEntry entry;
  final bool isMe;
  final String unit;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isMe ? AppColors.primarySoft : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isMe ? AppColors.primary.withValues(alpha: 0.45) : AppColors.line),
        boxShadow: flat || isMe ? null : AppShadows.soft,
      ),
      child: Row(children: [
        SizedBox(
          width: 34,
          child: Text('${e.rank}',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 15, color: isMe ? AppColors.primary : AppColors.text2)),
        ),
        const SizedBox(width: 8),
        PersonAvatar(name: e.name, size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(e.name ?? 'FITKEY member',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
              ),
              if (isMe) ...[const SizedBox(width: 6), const Tag('YOU', solid: true, dense: true)],
            ]),
            if (e.city != null)
              Text(e.city!, style: const TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
          ]),
        ),
        Text.rich(TextSpan(children: [
          TextSpan(text: formatNumber(e.score), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          TextSpan(
              text: ' $unit', style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600)),
        ])),
      ]),
    );
  }
}
