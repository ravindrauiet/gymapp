import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart' show formatDate;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../../widgets/rating_prompt.dart';
import '../../widgets/venue_card.dart';
import '../ai/ai_coach_screen.dart';
import '../auth/profile_setup_screen.dart';
import '../community/buddy_screens.dart';
import '../community/contest_detail_screen.dart';
import '../explore/explore_screen.dart';
import '../feed/feed_screen.dart';
import '../notifications/notifications_screen.dart';
import '../explore/venue_detail_screen.dart';
import '../health/health_report_screen.dart';
import '../healthstop/healthstop_screen.dart';
import '../nutrition/ai_food_scanner.dart';
import '../nutrition/fuel_log_screen.dart';
import '../plans/plans_screen.dart';
import '../profile/profile_screen.dart';
import '../store/store_screen.dart';
import '../trainers/trainers_screen.dart';
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
    // After the feed loads, ask about recent visits / sessions the member hasn't rated yet.
    _future.then((_) {
      if (mounted) promptPendingRatings(context);
    }).catchError((_) {});
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
    final user = session.user;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _reload,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _Header(name: user?.firstName, fullName: user?.name, city: user?.city),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              sliver: SliverList.list(
                children: [
                  _PassCard(subscription: session.subscription),
                  const DividerTitle("What's on your mind?", padding: EdgeInsets.fromLTRB(0, 26, 0, 14)),
                  const _CategoryRail(),
                  const SectionTitle('Everything fitness', subtitle: 'One app for training, food & recovery'),
                  const _ServiceGrid(),
                  const SizedBox(height: 20),
                  const _MansiCard(),
                  const SizedBox(height: 20),
                  const _PromoCarousel(),
                  FutureBuilder<_HomeData>(
                    future: _future,
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) return const _HomeSkeleton();
                      if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
                      return _Feed(data: snap.data!, city: user?.city);
                    },
                  ),
                  const _Footer(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.name, required this.fullName, required this.city});
  final String? name;
  final String? fullName;
  final String? city;

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 10, 16, 16),
      margin: const EdgeInsets.only(bottom: 16),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.location_on_rounded, color: AppColors.primary, size: 26),
              const SizedBox(width: 6),
              Expanded(
                child: Tap(
                  onTap: () => push(context, const ProfileSetupScreen(editing: true)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              city ?? 'Set your city',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.4),
                            ),
                          ),
                          const Icon(Icons.keyboard_arrow_down_rounded, size: 22),
                        ],
                      ),
                      Text(
                        '$_greeting, ${name ?? 'there'} 👋',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: AppColors.text2, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ),
              const NotificationBell(),
              const SizedBox(width: 10),
              Tap(
                onTap: () => push(context, const ProfileScreen()),
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.line, width: 2),
                  ),
                  child: PersonAvatar(name: fullName, size: 40),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          RotatingSearchBar(
            hints: const [
              "'gyms near me'",
              "'swimming pool'",
              "'yoga classes'",
              "'boxing'",
              "'badminton court'",
              "'zumba'",
            ],
            onTap: () => push(context, const ExploreScreen(standalone: true, autofocus: true)),
            trailing: Tap(
              onTap: () => push(context, const AiFoodScannerScreen()),
              child: const Icon(Icons.document_scanner_outlined, color: AppColors.primary, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// The member's FitKey Pass — styled like a premium membership card.
class _PassCard extends StatelessWidget {
  const _PassCard({required this.subscription});
  final ActiveSubscription? subscription;

  @override
  Widget build(BuildContext context) {
    final sub = subscription;
    final total = sub == null ? 1 : sub.endsAt.difference(sub.startsAt).inDays.clamp(1, 3650);
    final progress = sub == null ? 0.0 : (sub.daysLeft / total).clamp(0.0, 1.0);

    return Tap(
      onTap: () => push(context, const PlansScreen()),
      child: Container(
        decoration: BoxDecoration(
          gradient: AppColors.passGradient,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [BoxShadow(color: Color(0x331A1B25), blurRadius: 24, offset: Offset(0, 10))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              right: -40,
              top: -40,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.lime.withValues(alpha: 0.08)),
              ),
            ),
            Positioned(
              right: 24,
              bottom: -30,
              child: Icon(Icons.key_rounded, size: 130, color: Colors.white.withValues(alpha: 0.04)),
            ),
            Padding(padding: const EdgeInsets.all(20), child: sub == null ? _empty() : _active(sub, progress)),
          ],
        ),
      ),
    );
  }

  Widget _empty() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Row(
        children: [
          Icon(Icons.key_rounded, color: AppColors.lime, size: 18),
          SizedBox(width: 6),
          Text(
            'FITKEY PASS',
            style: TextStyle(color: AppColors.lime, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 2),
          ),
        ],
      ),
      const SizedBox(height: 12),
      const Text(
        'One pass. Every gym, pool\n& studio near you.',
        style: TextStyle(
          color: Colors.white,
          fontSize: 21,
          fontWeight: FontWeight.w800,
          height: 1.2,
          letterSpacing: -0.4,
        ),
      ),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: AppColors.lime, borderRadius: BorderRadius.circular(12)),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Explore plans',
              style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink),
            ),
            SizedBox(width: 6),
            Icon(Icons.arrow_forward_rounded, size: 18, color: AppColors.ink),
          ],
        ),
      ),
    ],
  );

  Widget _active(ActiveSubscription sub, double progress) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(Icons.key_rounded, color: AppColors.lime, size: 18),
          const SizedBox(width: 6),
          const Text(
            'FITKEY PASS',
            style: TextStyle(color: AppColors.lime, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 2),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: AppColors.green, borderRadius: BorderRadius.circular(20)),
            child: const Text(
              'ACTIVE',
              style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Text(
        sub.planName,
        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3),
      ),
      const SizedBox(height: 4),
      Text(
        sub.categories.map((c) => venueVisual(c).label).join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12.5, fontWeight: FontWeight.w500),
      ),
      const SizedBox(height: 18),
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${sub.daysLeft}',
            style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800, height: 1),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              'days left',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontWeight: FontWeight.w600),
            ),
          ),
          const Spacer(),
          Text(
            'Valid till ${formatDate(sub.endsAt)}',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 5,
          backgroundColor: Colors.white.withValues(alpha: 0.12),
          valueColor: const AlwaysStoppedAnimation(AppColors.lime),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------

class _CategoryRail extends StatelessWidget {
  const _CategoryRail();

  @override
  Widget build(BuildContext context) {
    final cats = venueVisuals.toList();
    return SizedBox(
      height: 104,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: cats.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (_, i) {
          final e = cats[i];
          return Tap(
            onTap: () => push(context, ExploreScreen(standalone: true, initialCategory: e.key)),
            child: SizedBox(
              width: 70,
              child: Column(
                children: [
                  Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: AppShadows.soft),
                    child: ClipOval(child: Image.asset(e.value.image, fit: BoxFit.cover)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    e.value.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.text),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ServiceGrid extends StatelessWidget {
  const _ServiceGrid();

  @override
  Widget build(BuildContext context) {
    // Order per BRD §2 (left → right, top → bottom). Mansi lives in the card below the grid.
    final items = <(String, String, IconData, Color, Color, Widget)>[
      ('Gym Buddy', 'Find a partner', Icons.people_alt_rounded, AppColors.teal, AppColors.tealSoft, const BuddyHubScreen()),
      ('Fuel Log', 'Calories', Icons.restaurant_rounded, AppColors.amber, AppColors.amberSoft, const FuelLogScreen()),
      ('Meal Scan', 'Snap & log', Icons.document_scanner_rounded, AppColors.green, AppColors.greenSoft, const AiFoodScannerScreen()),
      ('Progress', 'Your report', Icons.insights_rounded, AppColors.blue, AppColors.blueSoft, const HealthReportScreen()),
      ('Store', 'Gear & whey', Icons.shopping_bag_rounded, AppColors.pink, AppColors.pinkSoft, const StoreScreen()),
      ('HealthStop', 'Clinics', Icons.local_hospital_rounded, AppColors.red, AppColors.redSoft, const HealthStopScreen()),
      ('Trainers', 'Book 1:1', Icons.sports_rounded, AppColors.purple, AppColors.purpleSoft, const TrainersScreen()),
      ('FitFeed', 'Stories & tips', Icons.dynamic_feed_rounded, AppColors.primary, AppColors.primarySoft, const FitFeedScreen()),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        childAspectRatio: 0.7,
      ),
      itemBuilder: (_, i) {
        final (title, sub, icon, color, soft, screen) = items[i];
        return Tap(
          onTap: () => push(context, screen),
          child: Column(
            children: [
              // Takes whatever height the labels leave, so the tile never overflows on narrow screens.
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(20)),
                  child: Stack(
                    children: [
                      Positioned(
                        right: -8,
                        bottom: -8,
                        child: Icon(icon, size: 46, color: color.withValues(alpha: 0.12)),
                      ),
                      Center(child: Icon(icon, size: 30, color: color)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, letterSpacing: -0.1),
              ),
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, color: AppColors.text3, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------

class _MansiCard extends StatelessWidget {
  const _MansiCard();

  @override
  Widget build(BuildContext context) {
    const prompts = ['High-protein veg breakfast?', 'Plan my 4-day split', 'Fix my squat form'];
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFF2B1F5C), Color(0xFF4A2167), Color(0xFF6B2350)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: AppShadows.glow(AppColors.purple),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const MansiAvatar(size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Hi, I\'m Mansi',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    Text(
                      'Your personal AI fitness & diet coach',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in prompts)
                Tap(
                  onTap: () => push(context, AiCoachScreen(initialPrompt: p)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                    ),
                    child: Text(
                      p,
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Tap(
            onTap: () => push(context, const AiCoachScreen()),
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
              child: const Row(
                children: [
                  Expanded(
                    child: Text(
                      'Ask Mansi anything…',
                      style: TextStyle(color: AppColors.text3, fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                  ),
                  Icon(Icons.arrow_upward_rounded, color: AppColors.purple),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _PromoCarousel extends StatefulWidget {
  const _PromoCarousel();

  @override
  State<_PromoCarousel> createState() => _PromoCarouselState();
}

class _PromoCarouselState extends State<_PromoCarousel> {
  final _page = PageController(viewportFraction: 0.92);
  int _i = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_page.hasClients) return;
      _page.animateToPage((_i + 1) % 3, duration: const Duration(milliseconds: 500), curve: Curves.easeOutCubic);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banners = [
      PhotoBanner(
        image: AppImages.homeWorkout,
        eyebrow: 'FitPro on-demand',
        title: 'Train 1:1 with a certified coach',
        subtitle: 'Online, at home or at your gym',
        cta: 'Book a trainer',
        onTap: () => push(context, const TrainersScreen()),
      ),
      PhotoBanner(
        image: AppImages.foodBowl,
        eyebrow: 'AI meal scanner',
        title: 'Snap your plate. Get the macros.',
        subtitle: 'Calories, protein, carbs & more in seconds',
        cta: 'Scan a meal',
        tint: const Color(0xFF0B3B2A),
        onTap: () => push(context, const AiFoodScannerScreen()),
      ),
      PhotoBanner(
        image: AppImages.supplements,
        eyebrow: 'FitKey store',
        title: 'Whey, gear & wearables',
        subtitle: 'Genuine brands delivered to your door',
        cta: 'Shop now',
        tint: const Color(0xFF2A1B4A),
        onTap: () => push(context, const StoreScreen()),
      ),
    ];
    return Column(
      children: [
        SizedBox(
          height: 170,
          child: OverflowBox(
            maxWidth: MediaQuery.sizeOf(context).width,
            child: PageView.builder(
              controller: _page,
              itemCount: banners.length,
              onPageChanged: (i) => setState(() => _i = i),
              itemBuilder: (_, i) => Padding(padding: const EdgeInsets.symmetric(horizontal: 5), child: banners[i]),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            banners.length,
            (i) => AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == _i ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == _i ? AppColors.ink : AppColors.line,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _Feed extends StatelessWidget {
  const _Feed({required this.data, required this.city});
  final _HomeData data;
  final String? city;

  @override
  Widget build(BuildContext context) {
    final w = data.week;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'Your week',
          subtitle: w.currentStreak > 0
              ? '🔥 ${w.currentStreak}-day streak — keep it going!'
              : 'Check in today to start a streak',
          action: 'Report',
          onAction: () => push(context, const HealthReportScreen()),
        ),
        Row(
          children: [
            Expanded(
              child: MetricTile(label: 'Check-ins', value: '${w.totalCheckins}', icon: Icons.login_rounded),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MetricTile(
                label: 'Day streak',
                value: '${w.currentStreak}',
                icon: Icons.local_fire_department_rounded,
                color: AppColors.amber,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MetricTile(
                label: 'Workouts',
                value: '${w.workoutCount}',
                icon: Icons.bolt_rounded,
                color: AppColors.blue,
              ),
            ),
          ],
        ),
        if (data.contests.isNotEmpty) ...[
          SectionTitle(
            'Live challenges',
            subtitle: 'Compete with members in your city',
            action: 'See all',
            onAction: () => HomeShell.switchTab(context, HomeShell.community),
          ),
          SizedBox(
            height: 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: data.contests.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, i) => _ContestCard(contest: data.contests[i], index: i),
            ),
          ),
        ],
        SectionTitle(
          city == null ? 'Popular venues' : 'Top venues in $city',
          subtitle: 'Walk in with your FitKey Pass',
          action: 'See all',
          onAction: () => HomeShell.switchTab(context, HomeShell.explore),
        ),
        if (data.venues.isEmpty)
          const EmptyView(
            icon: Icons.place_rounded,
            title: 'No venues yet',
            message: 'New partners are joining every week.',
          )
        else
          ...data.venues.map(
            (v) => Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: VenueCard(
                venue: v,
                onTap: () => push(context, VenueDetailScreen(venueId: v.id)),
              ),
            ),
          ),
      ],
    );
  }
}

class _ContestCard extends StatelessWidget {
  const _ContestCard({required this.contest, required this.index});
  final Contest contest;
  final int index;

  static const _palettes = [
    [Color(0xFFFF7A45), Color(0xFFFF4B2B)],
    [Color(0xFF7C5CFF), Color(0xFF4F46E5)],
    [Color(0xFF14B8A6), Color(0xFF0E9F6E)],
  ];

  @override
  Widget build(BuildContext context) {
    final g = _palettes[index % _palettes.length];
    return Tap(
      onTap: () => push(context, ContestDetailScreen(contestId: contest.id)),
      child: Container(
        width: 250,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: g, begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(22),
          boxShadow: AppShadows.glow(g.last),
        ),
        child: Stack(
          children: [
            Positioned(
              right: -10,
              top: -6,
              child: Icon(Icons.emoji_events_rounded, size: 80, color: Colors.white.withValues(alpha: 0.15)),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Tag(
                      contest.period.toUpperCase(),
                      color: Colors.white,
                      bg: Colors.white.withValues(alpha: 0.2),
                      dense: true,
                    ),
                    const SizedBox(width: 6),
                    Tag(
                      '${contest.daysLeft}d left',
                      color: Colors.white,
                      bg: Colors.white.withValues(alpha: 0.2),
                      dense: true,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  contest.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800, height: 1.2),
                ),
                const SizedBox(height: 4),
                if (contest.reward != null)
                  Text(
                    '🏆 ${contest.reward}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const Spacer(),
                Row(
                  children: [
                    const Icon(Icons.groups_rounded, color: Colors.white, size: 16),
                    const SizedBox(width: 5),
                    Text(
                      '${contest.participantCount} joined',
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                      child: Text(
                        contest.joined ? 'Joined ✓' : 'Join',
                        style: TextStyle(color: g.last, fontWeight: FontWeight.w800, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 28),
          const SkeletonBox(height: 20, width: 140),
          const SizedBox(height: 14),
          Row(
            children: const [
              Expanded(child: SkeletonBox(height: 110, radius: 20)),
              SizedBox(width: 10),
              Expanded(child: SkeletonBox(height: 110, radius: 20)),
              SizedBox(width: 10),
              Expanded(child: SkeletonBox(height: 110, radius: 20)),
            ],
          ),
          const SizedBox(height: 28),
          const SkeletonBox(height: 20, width: 180),
          const SizedBox(height: 14),
          const SkeletonBox(height: 260, radius: 22),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 40, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sweat.\nUnlock.\nRepeat.',
            style: TextStyle(
              fontSize: 44,
              fontWeight: FontWeight.w800,
              height: 1.02,
              letterSpacing: -1.5,
              color: AppColors.text3.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text(
                'Crafted with ',
                style: TextStyle(color: AppColors.text3.withValues(alpha: 0.9), fontWeight: FontWeight.w600),
              ),
              const Icon(Icons.favorite_rounded, color: AppColors.primary, size: 16),
              Text(
                ' in India',
                style: TextStyle(color: AppColors.text3.withValues(alpha: 0.9), fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
