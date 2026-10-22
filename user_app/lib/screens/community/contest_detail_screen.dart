import 'package:fitkey_core/fitkey_core.dart' show formatDayDate, formatShortDate;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../health/log_sheets.dart';
import 'community_screen.dart';

typedef _ContestData = ({Contest contest, Leaderboard leaderboard});

class ContestDetailScreen extends StatefulWidget {
  const ContestDetailScreen({super.key, required this.contestId});

  final String contestId;

  @override
  State<ContestDetailScreen> createState() => _ContestDetailScreenState();
}

class _ContestDetailScreenState extends State<ContestDetailScreen> {
  late Future<_ContestData> _future;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_ContestData> _load() => context.read<Session>().api.contest(widget.contestId);

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* shown by the FutureBuilder */}
  }

  Future<void> _join() async {
    setState(() => _joining = true);
    try {
      await context.read<Session>().api.joinContest(widget.contestId);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      toast(context, "You're in! Good luck 💪");
      await _reload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _logRun() async {
    final logged = await showActivitySheet(context, initialType: 'running');
    if (logged && mounted) _reload();
  }

  static String _howTo(String metric) => switch (metric) {
        'running_km' => 'Log your runs from the Progress screen. Every kilometre between the start and end dates counts.',
        'streak' => 'Check in at any FITKEY venue on consecutive days. Your longest streak in the challenge window counts.',
        _ => 'Check in at any FITKEY venue. Each day you check in counts once.',
      };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ContestData>(
      future: _future,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null) {
          final loading = snap.connectionState != ConnectionState.done;
          return Scaffold(
            appBar: AppBar(title: const Text('Challenge')),
            body: loading
                ? const _DetailSkeleton()
                : ErrorView(error: snap.error ?? 'Could not load', onRetry: _reload),
          );
        }
        return _buildLoaded(data);
      },
    );
  }

  Widget _buildLoaded(_ContestData data) {
    final c = data.contest;
    final style = contestStyle(c);
    final g = style.colors;
    final finished = contestFinished(c);
    final upcoming = DateUtils.dateOnly(DateTime.now()).isBefore(DateUtils.dateOnly(c.startsOn));
    final me = data.leaderboard.me;
    final myId = context.read<Session>().user?.id;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: RefreshIndicator(
        color: AppColors.primary,
        edgeOffset: MediaQuery.paddingOf(context).top + kToolbarHeight,
        onRefresh: _reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 270,
              backgroundColor: g.last,
              foregroundColor: Colors.white,
              systemOverlayStyle: SystemUiOverlayStyle.light,
              flexibleSpace: _Hero(contest: c, colors: g, icon: style.icon, expandedHeight: 270),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              sliver: SliverList.list(children: [
                Row(children: [
                  Expanded(
                    child: MetricTile(
                        label: 'Players', value: '${c.participantCount}', icon: Icons.groups_rounded, color: g.last),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: MetricTile(
                      label: finished ? 'Status' : (upcoming ? 'Starts' : 'Days left'),
                      value: finished
                          ? 'Ended'
                          : (upcoming ? formatShortDate(c.startsOn) : '${c.daysLeft.clamp(0, 999)}'),
                      icon: Icons.timer_rounded,
                      color: AppColors.amber,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: MetricTile(
                      label: 'Your rank',
                      value: me == null ? '–' : '#${me.rank}',
                      icon: Icons.military_tech_rounded,
                      color: AppColors.primary,
                    ),
                  ),
                ]),
                if (c.reward != null && c.reward!.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  AppCard(
                    color: AppColors.amberSoft,
                    shadow: false,
                    child: Row(children: [
                      const IconBubble(Icons.card_giftcard_rounded, color: AppColors.amber, bg: Colors.white, size: 46),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('REWARD',
                              style: TextStyle(
                                  fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: Color(0xFFB86E00))),
                          const SizedBox(height: 2),
                          Text(c.reward!, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, height: 1.3)),
                        ]),
                      ),
                    ]),
                  ),
                ],
                if (c.description != null && c.description!.isNotEmpty) ...[
                  const SectionTitle('About this challenge'),
                  AppCard(
                    child: Text(c.description!, style: const TextStyle(color: AppColors.text2, height: 1.5, fontSize: 14.5)),
                  ),
                ],
                const SectionTitle('How it works'),
                AppCard(
                  child: Column(children: [
                    _Rule(icon: style.icon, color: g.last, text: _howTo(c.metric)),
                    _Rule(
                      icon: Icons.event_rounded,
                      color: AppColors.blue,
                      text: 'Counts from ${formatDayDate(c.startsOn)} to ${formatDayDate(c.endsOn)}.',
                    ),
                    if (c.city != null)
                      _Rule(icon: Icons.location_on_rounded, color: AppColors.pink, text: 'Open to members in ${c.city}.'),
                    _Rule(
                      icon: Icons.leaderboard_rounded,
                      color: AppColors.green,
                      text: 'Scores are measured in ${c.unit.isEmpty ? 'points' : c.unit} and the board updates as you train.',
                      last: true,
                    ),
                  ]),
                ),
                SectionTitle('Leaderboard',
                    subtitle: c.participantCount == 0 ? 'No one has joined yet' : '${c.participantCount} competing'),
                if (data.leaderboard.entries.isEmpty)
                  AppCard(
                    child: EmptyView(
                      icon: Icons.emoji_events_rounded,
                      color: AppColors.amber,
                      title: finished ? 'No scores recorded' : 'Be the first on the board',
                      message: finished ? null : 'Join and start training — your score shows up here.',
                    ),
                  )
                else
                  LeaderboardList(board: data.leaderboard, myUserId: myId, unit: c.unit, shrinkWrap: true),
              ]),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _actionBar(c, finished),
    );
  }

  Widget? _actionBar(Contest c, bool finished) {
    if (finished) {
      return const BottomActionBar(
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.flag_rounded, color: AppColors.text3, size: 20),
          SizedBox(width: 8),
          Text('This challenge has ended', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.text2)),
        ]),
      );
    }
    if (!c.joined) {
      return BottomActionBar(
        child: AppButton(label: 'Join challenge', icon: Icons.bolt_rounded, busy: _joining, onPressed: _join),
      );
    }
    final joinedBadge = Row(mainAxisSize: MainAxisSize.min, children: [
      const IconBubble(Icons.check_rounded, color: AppColors.green, size: 40),
      const SizedBox(width: 10),
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const Text("You're in", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        Text(c.metric == 'running_km' ? 'Log runs to score' : 'Check in to score',
            style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600)),
      ]),
    ]);
    if (c.metric == 'running_km') {
      return BottomActionBar(
        leading: joinedBadge,
        child: AppButton(label: 'Log a run', icon: Icons.directions_run_rounded, color: AppColors.ink, onPressed: _logRun),
      );
    }
    return BottomActionBar(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [joinedBadge]));
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.contest, required this.colors, required this.icon, required this.expandedHeight});
  final Contest contest;
  final List<Color> colors;
  final IconData icon;
  final double expandedHeight;

  @override
  Widget build(BuildContext context) {
    final c = contest;
    final top = MediaQuery.paddingOf(context).top;
    const glass = Color(0x33FFFFFF);
    return LayoutBuilder(builder: (context, cons) {
      final t = ((cons.maxHeight - top - kToolbarHeight) / (expandedHeight - kToolbarHeight)).clamp(0.0, 1.0);
      return Stack(fit: StackFit.expand, children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
        ),
        Positioned(
          right: -30,
          top: top + 10,
          child: Icon(Icons.emoji_events_rounded, size: 190, color: Colors.white.withValues(alpha: 0.12 * t)),
        ),
        Positioned(
          left: -40,
          bottom: -60,
          child: Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.07)),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 20,
          child: Opacity(
            opacity: t,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 6, runSpacing: 6, children: [
                Tag('${c.period.toUpperCase()} CHALLENGE', color: Colors.white, bg: glass, dense: true),
                Tag(contestTimeLabel(c), icon: Icons.schedule_rounded, color: Colors.white, bg: glass, dense: true),
                if (c.joined) const Tag('JOINED', icon: Icons.check_rounded, color: Colors.white, bg: glass, dense: true),
              ]),
              const SizedBox(height: 12),
              Text(c.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, height: 1.15, letterSpacing: -0.6)),
              const SizedBox(height: 10),
              Row(children: [
                Icon(icon, color: Colors.white, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${formatShortDate(c.startsOn)} – ${formatShortDate(c.endsOn)}'
                    ' · ${c.participantCount} joined${c.city != null ? ' · ${c.city}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
              ]),
            ]),
          ),
        ),
        Positioned(
          top: top,
          left: 56,
          right: 16,
          height: kToolbarHeight,
          child: IgnorePointer(
            child: Opacity(
              opacity: (1 - t * 2).clamp(0.0, 1.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(c.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}

class _Rule extends StatelessWidget {
  const _Rule({required this.icon, required this.color, required this.text, this.last = false});
  final IconData icon;
  final Color color;
  final String text;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconBubble(icon, color: color, size: 34),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(text, style: const TextStyle(height: 1.45, fontSize: 14, color: AppColors.text)),
          ),
        ),
      ]),
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SkeletonBox(height: 200, radius: 22),
          SizedBox(height: 16),
          Row(children: [
            Expanded(child: SkeletonBox(height: 104, radius: 20)),
            SizedBox(width: 10),
            Expanded(child: SkeletonBox(height: 104, radius: 20)),
            SizedBox(width: 10),
            Expanded(child: SkeletonBox(height: 104, radius: 20)),
          ]),
          SizedBox(height: 24),
          SkeletonBox(height: 18, width: 160),
          SizedBox(height: 12),
          SkeletonBox(height: 120, radius: 20),
        ]),
      ),
    );
  }
}
