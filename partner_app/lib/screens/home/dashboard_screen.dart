import 'package:fitkey_core/fitkey_core.dart' show formatDayDate, formatNumber;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../../widgets/brand.dart';
import '../../widgets/status.dart';
import '../attendance/attendance_screen.dart';
import '../auth/profile_screen.dart';
import '../checkin/checkin_code_screen.dart';
import '../events/partner_events_screen.dart';
import '../notifications/notifications_screen.dart';
import '../ratings/partner_ratings_screen.dart';
import '../trainer/partner_trainer_screen.dart';
import '../vendor/vendor_portal_screen.dart';
import '../venue/venue_editor_screen.dart';
import '../venue/venue_overview_screen.dart';

/// Signed-in shell: Home · Venues · Events · Business · Account.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _tab = 0;
  final _visited = <int>{0};
  late Future<List<VenueListItem>> _venues = _load();

  Future<List<VenueListItem>> _load() => context.read<PartnerSession>().api.venues();

  Future<void> _reload() async {
    final f = _load();
    setState(() => _venues = f);
    try {
      await f;
    } catch (_) {
      // Shown by the tab's error state.
    }
  }

  /// Pushes [screen] and refreshes the venue list when it closes (it may have changed a listing).
  Future<void> _open(Widget screen) async {
    await push<void>(context, screen);
    if (mounted) _reload();
  }

  void _goTab(int i) => setState(() {
        _tab = i;
        _visited.add(i);
      });

  @override
  Widget build(BuildContext context) {
    final nav = _Nav(venues: _venues, reload: _reload, open: _open, goTab: _goTab);
    final tabs = <Widget>[
      _HomeTab(nav: nav),
      _VenuesTab(nav: nav),
      const PartnerEventsScreen(),
      _BusinessTab(nav: nav),
      _AccountTab(nav: nav),
    ];
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [for (var i = 0; i < tabs.length; i++) _visited.contains(i) ? tabs[i] : const SizedBox.shrink()],
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: AppColors.surface,
          surfaceTintColor: Colors.transparent,
          indicatorColor: AppColors.primarySoft,
          height: 66,
          labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
                fontFamily: kFont,
                fontSize: 11.5,
                fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
                color: s.contains(WidgetState.selected) ? AppColors.text : AppColors.text2,
              )),
          iconTheme: WidgetStateProperty.resolveWith((s) =>
              IconThemeData(color: s.contains(WidgetState.selected) ? AppColors.primary : AppColors.text2, size: 24)),
        ),
        child: DecoratedBox(
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.line))),
          child: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _goTab,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
              NavigationDestination(
                  icon: Icon(Icons.storefront_outlined), selectedIcon: Icon(Icons.storefront_rounded), label: 'Venues'),
              NavigationDestination(
                  icon: Icon(Icons.event_outlined), selectedIcon: Icon(Icons.event_rounded), label: 'Events'),
              NavigationDestination(
                  icon: Icon(Icons.work_outline_rounded), selectedIcon: Icon(Icons.work_rounded), label: 'Business'),
              NavigationDestination(
                  icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: 'Account'),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the tabs need from the shell.
class _Nav {
  const _Nav({required this.venues, required this.reload, required this.open, required this.goTab});

  final Future<List<VenueListItem>> venues;
  final Future<void> Function() reload;
  final Future<void> Function(Widget screen) open;
  final void Function(int tab) goTab;

  /// Opens [build] for a live venue — directly when there's one, via a picker when there are several.
  Future<void> forLiveVenue(
    BuildContext context,
    List<VenueListItem> venues, {
    required String title,
    required Widget Function(VenueListItem v) build,
  }) async {
    final live = venues.where((v) => v.status == VenueStatus.live).toList();
    if (live.isEmpty) {
      toast(context, 'Available once one of your venues is live', icon: Icons.info_outline_rounded);
      return;
    }
    if (live.length == 1) return open(build(live.first));
    final picked = await showAppSheet<VenueListItem>(
      context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
              for (final v in live)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AppCard(
                    padding: const EdgeInsets.all(10),
                    border: true,
                    shadow: false,
                    onTap: () => Navigator.pop(ctx, v),
                    child: Row(children: [
                      NetImage(v.coverPhoto,
                          fallback: venueVisual(v.categories.firstOrNull ?? '').image, width: 52, height: 52, radius: 12),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(v.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w800)),
                          Text(v.location.isEmpty ? '${v.todayCheckins} check-ins today' : v.location,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                        ]),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
                    ]),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
    if (picked != null) await open(build(picked));
  }
}

// ---------------------------------------------------------------------------
// Home
// ---------------------------------------------------------------------------

class _HomeTab extends StatelessWidget {
  const _HomeTab({required this.nav});
  final _Nav nav;

  String _greeting() {
    final h = DateTime.now().hour;
    return h < 12 ? 'Good morning' : (h < 17 ? 'Good afternoon' : 'Good evening');
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<PartnerSession>().user;
    final top = MediaQuery.paddingOf(context).top;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(16, top + 12, 8, 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_greeting()}, ${user?.firstName ?? 'Partner'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            const SizedBox(height: 2),
            Text(formatDayDate(DateTime.now()),
                style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
        ),
        const PartnerNotificationBell(),
        Tap(
          onTap: () => nav.goTab(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: PersonAvatar(name: user?.name, size: 40),
          ),
        ),
      ]),
    );

    return FutureBuilder<List<VenueListItem>>(
      future: nav.venues,
      builder: (context, snap) {
        final failed = snap.connectionState == ConnectionState.done && snap.hasError;
        return RefreshIndicator(
          onRefresh: nav.reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              header,
              if (failed)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: ErrorView(error: snap.error!, onRetry: nav.reload),
                )
              else if (snap.hasData)
                ..._content(context, snap.data!)
              else
                const _HomeSkeleton(),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _content(BuildContext context, List<VenueListItem> venues) {
    final live = venues.where((v) => v.status == VenueStatus.live).toList();
    final today = venues.fold<int>(0, (s, v) => s + v.todayCheckins);
    final month = venues.fold<int>(0, (s, v) => s + v.monthCheckins);
    final rated = venues.where((v) => v.ratingAvg != null && v.ratingCount > 0).toList();
    final ratingCount = rated.fold<int>(0, (s, v) => s + v.ratingCount);
    final avgRating =
        ratingCount == 0 ? null : rated.fold<double>(0, (s, v) => s + v.ratingAvg! * v.ratingCount) / ratingCount;

    final actions = <_QuickAction>[
      _QuickAction(Icons.qr_code_2_rounded, 'Show QR', AppColors.primary, () {
        nav.forLiveVenue(context, venues,
            title: 'Show check-in QR for…', build: (v) => CheckinCodeScreen(venueId: v.id, venueName: v.name));
      }),
      _QuickAction(Icons.insights_rounded, 'Attendance', AppColors.blue, () {
        nav.forLiveVenue(context, venues,
            title: 'Attendance for…', build: (v) => AttendanceScreen(venueId: v.id, venueName: v.name));
      }),
      _QuickAction(Icons.event_rounded, 'Events', AppColors.purple, () => nav.goTab(2)),
      _QuickAction(Icons.star_rounded, 'Ratings', AppColors.amber, () => nav.open(const PartnerRatingsScreen())),
      _QuickAction(Icons.shopping_bag_rounded, 'Store', AppColors.green, () => nav.open(const VendorPortalScreen())),
      _QuickAction(Icons.sports_rounded, 'Trainer', AppColors.teal, () => nav.open(const PartnerTrainerScreen())),
    ];

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: _TodayCard(today: today, month: month, liveCount: live.length, total: venues.length),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(children: [
          Expanded(
            child: MetricTile(
              label: 'Live venues',
              value: '${live.length}',
              unit: 'of ${venues.length}',
              icon: Icons.storefront_rounded,
              color: AppColors.green,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: avgRating == null
                ? MetricTile(
                    label: 'Pending review',
                    value: '${venues.where((v) => v.status == VenueStatus.submitted || v.status == VenueStatus.underReview).length}',
                    icon: Icons.manage_search_rounded,
                    color: AppColors.blue,
                  )
                : MetricTile(
                    label: 'Avg rating · $ratingCount',
                    value: avgRating.toStringAsFixed(1),
                    unit: '★',
                    icon: Icons.star_rounded,
                    color: AppColors.amber,
                  ),
          ),
        ]),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: SectionTitle('Quick actions'),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.05,
          children: [for (final a in actions) _QuickActionTile(a)],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SectionTitle(
          'Your venues',
          subtitle: venues.isEmpty ? null : '${venues.length} listing${venues.length == 1 ? '' : 's'}',
          action: venues.length > 2 ? 'See all' : null,
          onAction: () => nav.goTab(1),
        ),
      ),
      if (venues.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: PhotoBanner(
            image: AppImages.gym,
            eyebrow: 'Get started',
            title: 'List your first venue',
            subtitle: 'Categories, photos, timings & facilities — verified by FITKEY, then members walk in.',
            cta: 'Start listing',
            height: 190,
            onTap: () => nav.open(const VenueEditorScreen()),
          ),
        )
      else ...[
        for (final v in venues.take(3))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: VenueCard(
              venue: v,
              onTap: () => nav.open(VenueOverviewScreen(venueId: v.id)),
              onShowQr: v.status == VenueStatus.live
                  ? () => nav.open(CheckinCodeScreen(venueId: v.id, venueName: v.name))
                  : null,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: PhotoBanner(
            image: AppImages.groupClass,
            eyebrow: 'Grow',
            title: 'Add another venue',
            subtitle: 'Run a pool, studio or second branch? List it in minutes.',
            cta: 'Add venue',
            height: 150,
            onTap: () => nav.open(const VenueEditorScreen()),
          ),
        ),
      ],
    ];
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.today, required this.month, required this.liveCount, required this.total});

  final int today;
  final int month;
  final int liveCount;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: BorderRadius.circular(22),
        boxShadow: AppShadows.glow(AppColors.primary),
      ),
      padding: const EdgeInsets.all(18),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('CHECK-INS TODAY',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4)),
            const SizedBox(height: 4),
            Text(formatNumber(today),
                style: const TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.w800, height: 1.05, letterSpacing: -1.5)),
            const SizedBox(height: 6),
            Text(
              total == 0
                  ? 'List a venue to start welcoming members'
                  : liveCount == 0
                      ? 'Check-ins start once a venue goes live'
                      : 'across $liveCount live venue${liveCount == 1 ? '' : 's'}',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(16)),
          child: Column(children: [
            const Icon(Icons.calendar_month_rounded, color: Colors.white, size: 20),
            const SizedBox(height: 6),
            Text(formatNumber(month), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
            Text('this month', style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }
}

class _QuickAction {
  const _QuickAction(this.icon, this.label, this.color, this.onTap);
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
}

class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile(this.a);
  final _QuickAction a;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: a.onTap,
      padding: const EdgeInsets.all(10),
      radius: 18,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconBubble(a.icon, color: a.color, size: 46),
        const SizedBox(height: 8),
        Text(a.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
      ]),
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SkeletonBox(height: 130, radius: 22),
          const SizedBox(height: 12),
          const Row(children: [
            Expanded(child: SkeletonBox(height: 104, radius: 20)),
            SizedBox(width: 12),
            Expanded(child: SkeletonBox(height: 104, radius: 20)),
          ]),
          const SizedBox(height: 28),
          const SkeletonBox(height: 18, width: 140),
          const SizedBox(height: 14),
          for (var r = 0; r < 2; r++) ...[
            const Row(children: [
              Expanded(child: SkeletonBox(height: 96, radius: 18)),
              SizedBox(width: 12),
              Expanded(child: SkeletonBox(height: 96, radius: 18)),
              SizedBox(width: 12),
              Expanded(child: SkeletonBox(height: 96, radius: 18)),
            ]),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 16),
          const SkeletonBox(height: 200, radius: 20),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Venues
// ---------------------------------------------------------------------------

class _VenuesTab extends StatelessWidget {
  const _VenuesTab({required this.nav});
  final _Nav nav;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your venues'), actions: const [PartnerNotificationBell(), SizedBox(width: 4)]),
      bottomNavigationBar: BottomActionBar(
        child: AppButton(
          label: 'Add a venue',
          icon: Icons.add_business_rounded,
          onPressed: () => nav.open(const VenueEditorScreen()),
        ),
      ),
      body: FutureBuilder<List<VenueListItem>>(
        future: nav.venues,
        builder: (context, snap) {
          final failed = snap.connectionState == ConnectionState.done && snap.hasError;
          if (!failed && !snap.hasData) return const SkeletonList(count: 3, itemHeight: 110);
          return RefreshIndicator(
            onRefresh: nav.reload,
            child: failed
                ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
                    const SizedBox(height: 60),
                    ErrorView(error: snap.error!, onRetry: nav.reload),
                  ])
                : snap.data!.isEmpty
                    ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
                        const SizedBox(height: 40),
                        EmptyView(
                          icon: Icons.storefront_rounded,
                          title: 'No venues yet',
                          message: 'List your gym, pool, studio or club. Once FITKEY verifies it, members can check in.',
                          action: SizedBox(
                            width: 200,
                            child: AppButton(
                              label: 'Start listing',
                              height: 48,
                              onPressed: () => nav.open(const VenueEditorScreen()),
                            ),
                          ),
                        ),
                      ])
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        itemCount: snap.data!.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 14),
                        itemBuilder: (context, i) {
                          final v = snap.data![i];
                          return VenueCard(
                            venue: v,
                            onTap: () => nav.open(VenueOverviewScreen(venueId: v.id)),
                            onShowQr: v.status == VenueStatus.live
                                ? () => nav.open(CheckinCodeScreen(venueId: v.id, venueName: v.name))
                                : null,
                          );
                        },
                      ),
          );
        },
      ),
    );
  }
}

/// Photo-led venue card: cover, status pill, location and today's check-ins.
class VenueCard extends StatelessWidget {
  const VenueCard({super.key, required this.venue, required this.onTap, this.onShowQr});

  final VenueListItem venue;
  final VoidCallback onTap;
  final VoidCallback? onShowQr;

  @override
  Widget build(BuildContext context) {
    final visual = venueVisual(venue.categories.firstOrNull ?? '');
    final live = venue.status == VenueStatus.live;
    return AppCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SizedBox(
            height: 150,
            child: Stack(fit: StackFit.expand, children: [
              NetImage(venue.coverPhoto, fallback: visual.image),
              const PhotoScrim(strength: 0.55),
              Positioned(left: 12, top: 12, child: StatusPill(venue.status, onPhoto: true)),
              Positioned(
                left: 14,
                right: 14,
                bottom: 12,
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final c in venue.categories.take(3))
                    Tag(venueVisual(c).label, icon: venueVisual(c).icon, color: Colors.white, bg: Colors.black.withValues(alpha: 0.35), dense: true),
                ]),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(venue.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: -0.2)),
                const SizedBox(height: 2),
                Row(children: [
                  const Icon(Icons.place_rounded, size: 14, color: AppColors.text3),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text(venue.location.isEmpty ? 'Location not added' : venue.location,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w500)),
                  ),
                ]),
                const SizedBox(height: 8),
                if (live)
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    Tag('${venue.todayCheckins} today', icon: Icons.login_rounded, color: AppColors.green),
                    Tag('${venue.monthCheckins} this month', icon: Icons.calendar_month_rounded, color: AppColors.blue),
                    if (venue.ratingAvg != null && venue.ratingCount > 0)
                      Tag('${venue.ratingAvg!.toStringAsFixed(1)} ★', color: AppColors.amber),
                  ])
                else if (venue.status == VenueStatus.rejected && venue.reviewNote != null)
                  Text(venue.reviewNote!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.red, fontSize: 12.5, fontWeight: FontWeight.w600))
                else
                  Text(
                    venue.status == VenueStatus.draft
                        ? 'Finish your listing and submit for review'
                        : 'FITKEY is reviewing your listing',
                    style: const TextStyle(color: AppColors.text3, fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
              ]),
            ),
            if (onShowQr != null)
              Tap(
                onTap: onShowQr,
                child: Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(14)),
                  child: const Column(children: [
                    Icon(Icons.qr_code_2_rounded, color: Colors.white, size: 22),
                    SizedBox(height: 2),
                    Text('QR', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                  ]),
                ),
              )
            else
              const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Business
// ---------------------------------------------------------------------------

class _BusinessTab extends StatelessWidget {
  const _BusinessTab({required this.nav});
  final _Nav nav;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Business'), actions: const [PartnerNotificationBell(), SizedBox(width: 4)]),
      body: FutureBuilder<List<VenueListItem>>(
        future: nav.venues,
        builder: (context, snap) {
          final venues = snap.data ?? const <VenueListItem>[];
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
            PhotoBanner(
              image: AppImages.supplements,
              eyebrow: 'FITKEY Store',
              title: 'Sell to FITKEY members',
              subtitle: 'Products, inventory, order dispatch & payouts.',
              cta: 'Open vendor portal',
              onTap: () => nav.open(const VendorPortalScreen()),
            ),
            const SizedBox(height: 14),
            PhotoBanner(
              image: AppImages.strength,
              eyebrow: 'FitPro',
              title: 'Coach members 1-on-1',
              subtitle: 'Trainer profile, verification, slots & bookings.',
              cta: 'Trainer profile',
              tint: const Color(0xFF0B2A3A),
              onTap: () => nav.open(const PartnerTrainerScreen()),
            ),
            const SectionTitle('Venue tools'),
            _ToolRow(
              icon: Icons.qr_code_2_rounded,
              color: AppColors.primary,
              title: 'Front-desk check-in QR',
              subtitle: 'Rotating QR + OTP for members',
              onTap: () => nav.forLiveVenue(context, venues,
                  title: 'Show check-in QR for…', build: (v) => CheckinCodeScreen(venueId: v.id, venueName: v.name)),
            ),
            _ToolRow(
              icon: Icons.insights_rounded,
              color: AppColors.blue,
              title: 'Attendance',
              subtitle: 'Daily visitors and monthly trends',
              onTap: () => nav.forLiveVenue(context, venues,
                  title: 'Attendance for…', build: (v) => AttendanceScreen(venueId: v.id, venueName: v.name)),
            ),
            _ToolRow(
              icon: Icons.event_rounded,
              color: AppColors.purple,
              title: 'Events',
              subtitle: 'Host classes, challenges and meetups',
              onTap: () => nav.goTab(2),
            ),
            _ToolRow(
              icon: Icons.star_rounded,
              color: AppColors.amber,
              title: 'Ratings & reviews',
              subtitle: 'What members say about your venues',
              onTap: () => nav.open(const PartnerRatingsScreen()),
            ),
            _ToolRow(
              icon: Icons.reviews_rounded,
              color: AppColors.teal,
              title: 'Trainer ratings',
              subtitle: 'Feedback on your coaching sessions',
              onTap: () => nav.open(const PartnerRatingsScreen(trainer: true)),
            ),
          ]);
        },
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.icon, required this.color, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          IconBubble(icon, color: color, size: 44),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Account
// ---------------------------------------------------------------------------

class _AccountTab extends StatelessWidget {
  const _AccountTab({required this.nav});
  final _Nav nav;

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You\'ll need your phone number and an OTP to log back in.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) await context.read<PartnerSession>().signOut();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<PartnerSession>().user;
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
        AppCard(
          onTap: () => push(context, const ProfileScreen(editing: true)),
          child: Row(children: [
            PersonAvatar(name: user?.name, size: 58),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(user?.name ?? 'Partner',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(user?.phone ?? '', style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600)),
                if (user?.email != null)
                  Text(user!.email!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.text3, fontSize: 12.5)),
              ]),
            ),
            const Tag('EDIT', icon: Icons.edit_rounded, dense: true),
          ]),
        ),
        const SectionTitle('Shortcuts'),
        _ToolRow(
          icon: Icons.notifications_rounded,
          color: AppColors.primary,
          title: 'Notifications',
          subtitle: 'Listing updates, bookings and orders',
          onTap: () => push(context, const PartnerNotificationsScreen()),
        ),
        _ToolRow(
          icon: Icons.storefront_rounded,
          color: AppColors.green,
          title: 'My venues',
          subtitle: 'Listings, check-in QR and attendance',
          onTap: () => nav.goTab(1),
        ),
        _ToolRow(
          icon: Icons.work_rounded,
          color: AppColors.blue,
          title: 'Store & trainer tools',
          subtitle: 'Vendor portal and FitPro trainer profile',
          onTap: () => nav.goTab(3),
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          icon: const Icon(Icons.logout_rounded, color: AppColors.red),
          label: const Text('Log out', style: TextStyle(color: AppColors.red)),
          onPressed: () => _logout(context),
        ),
        const SizedBox(height: 28),
        const Center(child: Opacity(opacity: 0.55, child: PartnerLockup(size: 22))),
        const SizedBox(height: 8),
        const Center(
          child: Text('Grow your fitness business with FITKEY',
              style: TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}
