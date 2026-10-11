import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import '../../widgets/venue_card.dart';
import '../community/buddy_screens.dart';
import '../community/contest_detail_screen.dart';
import '../explore/venue_detail_screen.dart';
import '../health/health_report_screen.dart';
import '../plans/plans_screen.dart';
import 'home_shell.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

typedef _HomeData = ({HealthReport week, List<Contest> contests, List<VenueSummary> venues});

class _HomeScreenState extends State<HomeScreen> {
  late Future<_HomeData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_HomeData> _load() async {
    final session = context.read<Session>();
    final api = session.api;
    final results = await Future.wait([
      api.healthReport(days: 7),
      api.contests(),
      api.venues(city: session.user?.city, limit: 8),
      session.refresh(),
    ]);
    var venues = results[2] as List<VenueSummary>;
    if (venues.isEmpty) venues = await api.venues(limit: 8); // no venues in my city yet → show all
    return (week: results[0] as HealthReport, contests: results[1] as List<Contest>, venues: venues);
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Hi ${session.user?.firstName ?? ''} 👋',
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 2),
                      const Text('Ready to unlock today\'s workout?', style: TextStyle(color: FkColors.textSecondary)),
                    ]),
                  ),
                  const FitKeyLogo(size: 36, showWordmark: false),
                ],
              ),
              const SizedBox(height: 20),
              _MembershipCard(subscription: session.subscription),
              const SizedBox(height: 16),
              const _QuickActions(),
              FutureBuilder<_HomeData>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
                  }
                  if (snap.hasError) return ErrorState(message: errorMessage(snap.error!), onRetry: _reload);
                  final data = snap.data!;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionHeader('This week',
                          actionLabel: 'Full report',
                          onAction: () => Navigator.push(
                              context, MaterialPageRoute(builder: (_) => const HealthReportScreen()))),
                      Row(children: [
                        Expanded(
                            child: StatTile(
                                label: 'Check-ins', value: '${data.week.totalCheckins}', icon: Icons.login)),
                        const SizedBox(width: 10),
                        Expanded(
                            child: StatTile(
                                label: 'Day streak',
                                value: '${data.week.currentStreak}',
                                icon: Icons.local_fire_department,
                                color: FkColors.orange)),
                        const SizedBox(width: 10),
                        Expanded(
                            child: StatTile(
                                label: 'Workouts',
                                value: '${data.week.workoutCount}',
                                icon: Icons.bolt,
                                color: FkColors.sky)),
                      ]),
                      if (data.contests.isNotEmpty) ...[
                        SectionHeader('Live contests',
                            actionLabel: 'See all', onAction: () => HomeShell.switchTab(context, HomeShell.community)),
                        SizedBox(
                          height: 150,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: data.contests.length,
                            separatorBuilder: (_, _) => const SizedBox(width: 12),
                            itemBuilder: (_, i) => _ContestCard(contest: data.contests[i]),
                          ),
                        ),
                      ],
                      SectionHeader(
                        session.user?.city == null ? 'Venues' : 'Venues in ${session.user!.city}',
                        actionLabel: 'Explore',
                        onAction: () => HomeShell.switchTab(context, HomeShell.explore),
                      ),
                      SizedBox(
                        height: 230,
                        child: data.venues.isEmpty
                            ? const EmptyState(icon: Icons.place_outlined, title: 'No venues yet')
                            : ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: data.venues.length,
                                separatorBuilder: (_, _) => const SizedBox(width: 12),
                                itemBuilder: (_, i) => SizedBox(
                                  width: 240,
                                  child: VenueCard(
                                    venue: data.venues[i],
                                    compact: true,
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(builder: (_) => VenueDetailScreen(venueId: data.venues[i].id)),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MembershipCard extends StatelessWidget {
  const _MembershipCard({required this.subscription});

  final ActiveSubscription? subscription;

  @override
  Widget build(BuildContext context) {
    final sub = subscription;
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlansScreen())),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: sub == null
              ? const LinearGradient(colors: [Color(0xFF2A2F37), Color(0xFF1B1F25)])
              : const LinearGradient(
                  colors: [FkColors.lime, Color(0xFF8BD81D)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: sub == null
            ? Row(children: [
                const Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Get your FitKey', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                    SizedBox(height: 4),
                    Text('Pick a plan to unlock gyms, pools, sports & more.',
                        style: TextStyle(color: FkColors.textSecondary)),
                  ]),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(color: FkColors.lime, shape: BoxShape.circle),
                  child: const Icon(Icons.arrow_forward, color: Colors.black),
                ),
              ])
            : DefaultTextStyle(
                style: const TextStyle(color: Colors.black),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.key, color: Colors.black),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(sub.planName,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.black)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(20)),
                      child: const Text('ACTIVE',
                          style: TextStyle(color: FkColors.lime, fontSize: 11, fontWeight: FontWeight.w800)),
                    ),
                  ]),
                  const SizedBox(height: 18),
                  Text('${sub.daysLeft} days left',
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.black)),
                  Text('Valid till ${formatDate(sub.endsAt)}', style: const TextStyle(color: Colors.black87)),
                ]),
              ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    Widget action(IconData icon, String label, Color color, VoidCallback onTap) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: FkColors.surface,
                border: Border.all(color: FkColors.outline),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(children: [
                Icon(icon, color: color),
                const SizedBox(height: 6),
                Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        );

    return Row(children: [
      action(Icons.card_membership, 'Plans', FkColors.lime,
          () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlansScreen()))),
      const SizedBox(width: 10),
      action(Icons.people_alt_outlined, 'Gym buddy', FkColors.orange,
          () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateBuddyPostScreen()))),
      const SizedBox(width: 10),
      action(Icons.play_circle_outline, 'Videos', FkColors.violet, () => HomeShell.switchTab(context, HomeShell.studio)),
      const SizedBox(width: 10),
      action(Icons.insights, 'Progress', FkColors.sky,
          () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HealthReportScreen()))),
    ]);
  }
}

class _ContestCard extends StatelessWidget {
  const _ContestCard({required this.contest});

  final Contest contest;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => ContestDetailScreen(contestId: contest.id))),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.emoji_events, color: Color(0xFFFFC145), size: 20),
                const SizedBox(width: 6),
                Text(contest.period.toUpperCase(),
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: FkColors.textSecondary)),
                const Spacer(),
                Text('${contest.daysLeft}d left', style: const TextStyle(fontSize: 12, color: FkColors.orange)),
              ]),
              const SizedBox(height: 10),
              Text(contest.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(contest.reward ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
              const Spacer(),
              Text(contest.joined ? '✓ Joined · ${contest.participantCount} players' : '${contest.participantCount} players',
                  style: TextStyle(
                      fontSize: 12, color: contest.joined ? FkColors.lime : FkColors.textSecondary,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ),
    );
  }
}
