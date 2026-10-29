import 'package:fitkey_core/fitkey_core.dart' show formatDayDate, formatShortDate, formatNumber, ApiException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/events_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../arena/arena_exercise_screen.dart';
import '../checkin/checkin_screen.dart';
import '../explore/venue_detail_screen.dart';
import '../health/log_sheets.dart';
import 'event_widgets.dart';
import 'leaderboard_list.dart';
import 'org_verify_sheet.dart';

/// Event detail (BRD §3.1): about, rules per format, who can join (org verification), own leaderboard,
/// org filter and inter-org team ranking. Kept as `ContestDetailScreen` because Home and notifications open it.
class ContestDetailScreen extends StatefulWidget {
  const ContestDetailScreen({super.key, required this.contestId});

  final String contestId;

  @override
  State<ContestDetailScreen> createState() => _ContestDetailScreenState();
}

class _ContestDetailScreenState extends State<ContestDetailScreen> {
  late Future<EventDetail> _future;
  bool _busy = false;

  /// Leaderboard filter: null = everyone, otherwise one org.
  String? _boardOrg;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<EventDetail> _load() => context.read<Session>().api.event(widget.contestId, orgId: _boardOrg);

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* shown by the FutureBuilder */}
  }

  Future<void> _join(EventDetail d) async {
    final el = d.eligibility;
    if (el.reason == 'org_verification') {
      final m = await showOrgVerifySheet(context, orgs: el.orgs);
      if (m == null || !mounted) return;
      if (!m.verified) {
        toast(context, "ID sent for review — we'll notify you once approved");
        _reload();
        return;
      }
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<Session>().api.joinEvent(widget.contestId);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      toast(context, d.event.format == 'onground' ? "You're registered! See you there" : "You're in! Good luck 💪");
      await _reload();
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && e.statusCode == 403) {
        _reload(); // eligibility changed (e.g. verification needed)
      }
      toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave this event?'),
        content: const Text('Your spot on the leaderboard will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<Session>().api.leaveEvent(widget.contestId);
      if (mounted) _reload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _logRun() async {
    final logged = await showActivitySheet(context, initialType: 'running');
    if (logged && mounted) _reload();
  }

  Future<void> _openArena(FitEvent e) async {
    await push(context, ArenaExerciseScreen(exerciseId: e.arenaExercise!));
    if (mounted) _reload();
  }

  Future<void> _checkIn(FitEvent e) async {
    await push(context, CheckinScreen(venueId: e.venue?.id, venueName: e.venue?.name));
    if (mounted) _reload();
  }

  static String _howTo(FitEvent e) => switch (e.metric) {
        'running_km' => 'Log your runs from the Progress screen. Every kilometre between the start and end dates counts.',
        'streak' => 'Check in at any FITKEY venue on consecutive days. Your longest streak in the event window counts.',
        'attendance' =>
          'Register here, then on the event day check in at ${e.venue?.name ?? 'the venue'} with its QR code — your attendance is marked automatically.',
        'arena_reps' =>
          'Do your set in the AI Arena (${_exerciseName(e.arenaExercise)}). The camera counts only clean, full-range reps — your best set counts.',
        _ => 'Check in at any FITKEY venue. Each day you check in counts once.',
      };

  static String _exerciseName(String? id) => switch (id) {
        'pushups' => 'Push-ups',
        'pullups' => 'Pull-ups',
        'squats' => 'Squats',
        'plank' => 'Plank',
        'burpees' => 'Burpees',
        null => 'AI Arena',
        _ => id[0].toUpperCase() + id.substring(1),
      };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EventDetail>(
      future: _future,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null) {
          final loading = snap.connectionState != ConnectionState.done;
          return Scaffold(
            appBar: AppBar(title: const Text('Event')),
            body: loading ? const _DetailSkeleton() : ErrorView(error: snap.error ?? 'Could not load', onRetry: _reload),
          );
        }
        return _buildLoaded(data);
      },
    );
  }

  Widget _buildLoaded(EventDetail d) {
    final e = d.event;
    final look = eventStyle(e);
    final g = look.colors;
    final me = d.me;
    final myId = context.read<Session>().user?.id;
    final orgFilterOptions = <String?>[null, ...{for (final o in [...e.battleOrgs, ...d.eligibility.orgs]) o.id}];
    String orgName(String id) =>
        [...e.battleOrgs, ...d.eligibility.orgs].firstWhere((o) => o.id == id, orElse: () => d.eligibility.orgs.first).name;

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
              expandedHeight: 290,
              backgroundColor: g.last,
              foregroundColor: Colors.white,
              systemOverlayStyle: SystemUiOverlayStyle.light,
              actions: [
                if (e.joined && !e.finished && !e.attended)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (_) => _leave(),
                    itemBuilder: (_) => const [PopupMenuItem(value: 'leave', child: Text('Leave event'))],
                  ),
              ],
              flexibleSpace: _Hero(event: e, look: look, expandedHeight: 290),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              sliver: SliverList.list(children: [
                Row(children: [
                  Expanded(
                    child: MetricTile(label: 'Players', value: '${e.participantCount}', icon: Icons.groups_rounded, color: g.last),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: MetricTile(
                      label: e.finished ? 'Status' : (e.upcoming ? 'Starts' : 'When'),
                      value: e.finished ? 'Ended' : eventTimeLabel(e),
                      icon: Icons.timer_rounded,
                      color: AppColors.amber,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: MetricTile(
                      label: e.metric == 'attendance' ? 'Attendance' : 'Your rank',
                      value: e.metric == 'attendance' ? (e.attended ? 'Done' : '–') : (me == null ? '–' : '#${me.rank}'),
                      icon: e.metric == 'attendance' ? Icons.how_to_reg_rounded : Icons.military_tech_rounded,
                      color: AppColors.primary,
                    ),
                  ),
                ]),
                if (d.eligibility.reason == 'org_verification' ||
                    d.eligibility.reason == 'org_pending' ||
                    d.eligibility.reason == 'venue_members' ||
                    d.eligibility.reason == 'city') ...[
                  const SizedBox(height: 14),
                  _EligibilityCard(eligibility: d.eligibility),
                ],
                if (e.reward != null && e.reward!.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  AppCard(
                    color: AppColors.amberSoft,
                    shadow: false,
                    child: Row(children: [
                      const IconBubble(Icons.card_giftcard_rounded, color: AppColors.amber, bg: Colors.white, size: 46),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(e.sponsor != null ? 'REWARD · BY ${e.sponsor!.toUpperCase()}' : 'REWARD',
                              style: const TextStyle(
                                  fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: Color(0xFFB86E00))),
                          const SizedBox(height: 2),
                          Text(e.reward!, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, height: 1.3)),
                        ]),
                      ),
                    ]),
                  ),
                ],
                if (e.venue != null) ...[
                  const SectionTitle('Venue'),
                  AppCard(
                    onTap: () => push(context, VenueDetailScreen(venueId: e.venue!.id)),
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      NetImage(e.venue!.photo, fallback: AppImages.gym, width: 64, height: 64, radius: 14),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(e.venue!.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                          const SizedBox(height: 2),
                          Text(
                            [e.venue!.area, e.venue!.city].whereType<String>().join(', '),
                            style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600),
                          ),
                          if (e.eventDate != null) ...[
                            const SizedBox(height: 4),
                            Tag(formatDayDate(e.eventDate!), icon: Icons.event_rounded, color: AppColors.blue, dense: true),
                          ],
                        ]),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
                    ]),
                  ),
                ],
                if (e.description != null && e.description!.isNotEmpty) ...[
                  const SectionTitle('About this event'),
                  AppCard(
                    child: Text(e.description!, style: const TextStyle(color: AppColors.text2, height: 1.5, fontSize: 14.5)),
                  ),
                ],
                const SectionTitle('How it works'),
                AppCard(
                  child: Column(children: [
                    _Rule(icon: look.icon, color: g.last, text: _howTo(e)),
                    _Rule(
                      icon: Icons.event_rounded,
                      color: AppColors.blue,
                      text: e.format == 'onground' && e.eventDate != null
                          ? 'Registration open till ${formatDayDate(e.endsOn)}. Event day: ${formatDayDate(e.eventDate!)}.'
                          : 'Counts from ${formatDayDate(e.startsOn)} to ${formatDayDate(e.endsOn)}.',
                    ),
                    _Rule(icon: Icons.verified_user_rounded, color: AppColors.purple, text: _whoCanJoin(e)),
                    if (e.registrationFeePaise > 0)
                      _Rule(
                        icon: Icons.currency_rupee_rounded,
                        color: AppColors.amber,
                        text: 'Registration fee ${eventFeeLabel(e)}, payable at the venue on the event day.',
                      ),
                    if (e.isBattle)
                      _Rule(
                        icon: Icons.sports_kabaddi_rounded,
                        color: AppColors.pink,
                        text: 'Inter-org battle: teams are ranked by the average score of their members, plus an individual board.',
                      ),
                    _Rule(
                      icon: Icons.leaderboard_rounded,
                      color: AppColors.green,
                      text: e.metric == 'attendance'
                          ? 'Everyone who checks in on the day is marked as attended.'
                          : 'Scores are measured in ${e.unit.isEmpty ? 'points' : e.unit} and the board updates as you train.',
                      last: true,
                    ),
                  ]),
                ),
                if (d.teams != null && d.teams!.isNotEmpty) ...[
                  const SectionTitle('Team ranking', subtitle: 'Average score per member'),
                  _TeamBoard(teams: d.teams!, unit: e.unit, myOrgId: me?.orgId),
                ],
                SectionTitle('Leaderboard',
                    subtitle: e.participantCount == 0 ? 'No one has joined yet' : '${e.participantCount} competing'),
                if (orgFilterOptions.length > 1) ...[
                  ChoiceChips<String?>(
                    padding: EdgeInsets.zero,
                    options: orgFilterOptions,
                    selected: _boardOrg,
                    label: (id) => id == null ? 'Everyone' : orgName(id),
                    icon: (id) => id == null ? Icons.public_rounded : Icons.business_rounded,
                    onSelected: (id) {
                      if (id == _boardOrg) return;
                      _boardOrg = id;
                      _reload();
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                if (d.entries.isEmpty)
                  AppCard(
                    child: EmptyView(
                      icon: Icons.emoji_events_rounded,
                      color: AppColors.amber,
                      title: e.finished ? 'No scores recorded' : 'Be the first on the board',
                      message: e.finished ? null : 'Join and start training — your score shows up here.',
                    ),
                  )
                else
                  LeaderboardList(board: d.leaderboard, myUserId: myId, unit: e.unit, shrinkWrap: true),
              ]),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _actionBar(d),
    );
  }

  static String _whoCanJoin(FitEvent e) {
    if (e.isBattle) return 'Open to verified members of ${e.battleOrgs.map((o) => o.name).join(', ')}.';
    if (e.kind == 'org') {
      return 'Only for verified ${e.orgKind == 'college' ? 'students' : 'employees'} of ${e.orgName ?? 'the organisation'}.';
    }
    if (e.kind == 'partner' && e.membersOnly) {
      return 'Only for ${e.venue?.name ?? 'venue'} members — anyone who has checked in there or holds a plan covering it.';
    }
    if (e.city != null) return 'Open to FitKey members in ${e.city}.';
    return 'Open to every FitKey member — no verification needed.';
  }

  Widget? _actionBar(EventDetail d) {
    final e = d.event;
    final el = d.eligibility;
    if (e.finished) {
      return BottomActionBar(
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(e.attended ? Icons.how_to_reg_rounded : Icons.flag_rounded, color: AppColors.text3, size: 20),
          const SizedBox(width: 8),
          Text(e.attended ? 'You attended this event' : 'This event has ended',
              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.text2)),
        ]),
      );
    }
    if (!e.joined) {
      final (label, icon, onPressed) = switch (el.reason) {
        'org_verification' => ('Verify & join', Icons.verified_user_rounded, () => _join(d)),
        'org_pending' => ('ID under review', Icons.hourglass_top_rounded, null),
        'venue_members' => ('Venue members only', Icons.lock_rounded, null),
        'city' => (el.message ?? 'Not available in your city', Icons.location_off_rounded, null),
        _ => (
            e.format == 'onground' ? 'Register${e.registrationFeePaise > 0 ? ' · ${eventFeeLabel(e)}' : ' free'}' : 'Join event',
            Icons.bolt_rounded,
            () => _join(d),
          ),
      };
      return BottomActionBar(
        child: AppButton(label: label, icon: icon, busy: _busy, onPressed: onPressed),
      );
    }
    final joinedBadge = Row(mainAxisSize: MainAxisSize.min, children: [
      IconBubble(e.attended ? Icons.how_to_reg_rounded : Icons.check_rounded, color: AppColors.green, size: 40),
      const SizedBox(width: 10),
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(e.attended ? 'Attended' : "You're in", style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        Text(
          switch (e.metric) {
            'running_km' => 'Log runs to score',
            'arena_reps' => 'Best AI set counts',
            'attendance' => e.attended ? 'See you next time' : 'Check in on the day',
            _ => 'Check in to score',
          },
          style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600),
        ),
      ]),
    ]);
    final today = DateUtils.dateOnly(DateTime.now());
    final Widget? action = switch (e.metric) {
      'running_km' => AppButton(label: 'Log a run', icon: Icons.directions_run_rounded, color: AppColors.ink, onPressed: _logRun),
      'arena_reps' when e.arenaExercise != null && !e.upcoming => AppButton(
          label: 'Go to AI Arena', icon: Icons.auto_awesome_rounded, color: AppColors.ink, onPressed: () => _openArena(e)),
      'attendance' when !e.attended && e.eventDate != null && DateUtils.dateOnly(e.eventDate!) == today => AppButton(
          label: 'Check in now', icon: Icons.qr_code_scanner_rounded, color: AppColors.ink, onPressed: () => _checkIn(e)),
      _ => null,
    };
    if (action != null) return BottomActionBar(leading: joinedBadge, child: action);
    return BottomActionBar(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [joinedBadge]));
  }
}

class _EligibilityCard extends StatelessWidget {
  const _EligibilityCard({required this.eligibility});
  final EventEligibility eligibility;

  @override
  Widget build(BuildContext context) {
    final pending = eligibility.reason == 'org_pending';
    final c = pending ? AppColors.amber : AppColors.purple;
    return AppCard(
      color: pending ? AppColors.amberSoft : AppColors.purpleSoft,
      shadow: false,
      child: Row(children: [
        IconBubble(pending ? Icons.hourglass_top_rounded : Icons.lock_person_rounded, color: c, bg: Colors.white, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(eligibility.message ?? 'Verification needed',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, height: 1.3)),
            if (eligibility.reason == 'org_verification') ...[
              const SizedBox(height: 3),
              const Text('Use your official email, an invite code, or your college ID.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
      ]),
    );
  }
}

class _TeamBoard extends StatelessWidget {
  const _TeamBoard({required this.teams, required this.unit, required this.myOrgId});
  final List<EventTeam> teams;
  final String unit;
  final String? myOrgId;

  static const _medals = [Color(0xFFFFB800), Color(0xFFA9B2BF), Color(0xFFCD7F4A)];

  @override
  Widget build(BuildContext context) {
    final top = teams.isEmpty ? 1.0 : teams.map((t) => t.averageScore).reduce((a, b) => a > b ? a : b);
    return AppCard(
      child: Column(children: [
        for (final t in teams) ...[
          Row(children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.rank <= 3 ? _medals[t.rank - 1] : AppColors.surfaceAlt,
                shape: BoxShape.circle,
              ),
              child: Text('${t.rank}',
                  style: TextStyle(fontWeight: FontWeight.w800, color: t.rank <= 3 ? Colors.white : AppColors.text2)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(t.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  if (t.orgId == myOrgId) ...[const SizedBox(width: 6), const Tag('YOUR TEAM', solid: true, dense: true)],
                ]),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: top <= 0 ? 0 : (t.averageScore / top).clamp(0.0, 1.0),
                    minHeight: 7,
                    backgroundColor: AppColors.surfaceAlt,
                    color: t.orgId == myOrgId ? AppColors.primary : AppColors.purple,
                  ),
                ),
                const SizedBox(height: 4),
                Text('${t.members} ${t.members == 1 ? 'member' : 'members'} · total ${formatNumber(t.totalScore)} $unit',
                    style: const TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
              ]),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(formatNumber(t.averageScore), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              Text('avg $unit', style: const TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
            ]),
          ]),
          if (t != teams.last) const Divider(height: 24),
        ],
      ]),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.event, required this.look, required this.expandedHeight});
  final FitEvent event;
  final EventLook look;
  final double expandedHeight;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final kind = eventKindStyle(e);
    final top = MediaQuery.paddingOf(context).top;
    const glass = Color(0x33FFFFFF);
    return LayoutBuilder(builder: (context, cons) {
      final t = ((cons.maxHeight - top - kToolbarHeight) / (expandedHeight - kToolbarHeight)).clamp(0.0, 1.0);
      return Stack(fit: StackFit.expand, children: [
        NetImage(e.coverUrl ?? e.venue?.photo, fallback: look.image),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [look.colors.first.withValues(alpha: 0.55), look.colors.last.withValues(alpha: 0.95)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
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
                Tag(kind.label, icon: kind.icon, color: kind.color, bg: Colors.white, dense: true),
                Tag('${eventFormatLabel(e).toUpperCase()} · ${look.metricLabel.toUpperCase()}',
                    color: Colors.white, bg: glass, dense: true),
                Tag(eventTimeLabel(e), icon: Icons.schedule_rounded, color: Colors.white, bg: glass, dense: true),
                if (e.joined)
                  Tag(e.attended ? 'ATTENDED' : 'JOINED', icon: Icons.check_rounded, color: Colors.white, bg: glass, dense: true),
              ]),
              const SizedBox(height: 12),
              Text(e.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, height: 1.15, letterSpacing: -0.6)),
              const SizedBox(height: 10),
              Row(children: [
                Icon(look.icon, color: Colors.white, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${formatShortDate(e.startsOn)} – ${formatShortDate(e.endsOn)} · ${eventAudience(e)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
              ]),
            ]),
          ),
        ),
        Positioned(
          top: top,
          left: 56,
          right: 56,
          height: kToolbarHeight,
          child: IgnorePointer(
            child: Opacity(
              opacity: (1 - t * 2).clamp(0.0, 1.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(e.title,
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
