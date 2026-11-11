import 'package:fitkey_core/fitkey_core.dart' show formatDayDate, formatNumber, formatPaise;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/brd_api.dart';
import '../../data/models.dart';
import '../../data/rse_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../../widgets/agreement_sheet.dart';
import '../../widgets/commission_plan_card.dart';
import '../../widgets/status.dart';
import '../../widgets/status_timeline.dart';
import '../attendance/attendance_screen.dart';
import '../checkin/checkin_code_screen.dart';
import '../events/partner_events_screen.dart';
import '../notifications/notifications_screen.dart';
import '../ratings/partner_ratings_screen.dart';
import '../run/member_register_screen.dart';
import '../run/scan_checkin_screen.dart';
import '../run/slot_board_screen.dart';
import '../run/type_run_screens.dart';
import '../trainer/partner_trainer_screen.dart';
import '../vendor/vendor_portal_screen.dart';
import '../venue/venue_overview_screen.dart';
import 'listing_nav.dart';
import 'shell.dart';
import 'venue_card.dart';

/// Everything Home shows, loaded together.
class HomeData {
  HomeData({required this.venues, this.home, this.typeListing, this.checklist, required this.type, this.typeEarnings});

  final PartnerType type;
  final List<VenueListItem> venues;

  /// GET /partner/home (null when the server doesn't answer — Home then falls back to the venue list).
  final PartnerHome? home;

  /// Trainer / clinic / chemist / store listing state.
  final TypeListingState? typeListing;
  final SetupChecklist? checklist;

  /// Trainer / clinic / chemist / store earnings (their own endpoint; /partner/home only covers venues).
  final EarningsBreakdown? typeEarnings;

  bool get live => type.isVenue
      ? (home?.live ?? false) || venues.any((v) => v.status == VenueStatus.live)
      : typeListing?.status == VenueStatus.live || (home?.live ?? false);

  /// The venue still being set up (first one that isn't live).
  VenueListItem? get setupVenue => venues.where((v) => v.status != VenueStatus.live).firstOrNull;
}

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  Future<HomeData>? _future;
  Future<List<VenueListItem>>? _venuesSeen;
  bool _handoverChecked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = PartnerShell.of(context);
    if (!identical(shell.venues, _venuesSeen)) {
      _venuesSeen = shell.venues;
      _future = _load(shell);
    }
    if (!_handoverChecked) {
      _handoverChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkHandover());
    }
  }

  Future<HomeData> _load(PartnerShell shell) async {
    final api = context.read<PartnerSession>().api;
    final type = shell.type;
    final results = await Future.wait<Object?>([
      shell.venues.then<Object?>((v) => v, onError: (_) => <VenueListItem>[]),
      api.home().then<Object?>((h) => h, onError: (_) => null),
      if (!type.isVenue) api.typeListing(type).then<Object?>((t) => t, onError: (_) => null),
    ]);
    final venues = results[0] as List<VenueListItem>;
    final home = results[1] as PartnerHome?;
    final typeListing = type.isVenue ? null : results[2] as TypeListingState?;
    var checklist = type.isVenue ? home?.checklist : typeListing?.checklist;
    if (type.isVenue && checklist == null) {
      final setup = venues.where((v) => v.status != VenueStatus.live).firstOrNull;
      if (setup != null) checklist = await api.venueChecklist(setup.id).catchError((_) => null);
    }
    EarningsBreakdown? typeEarnings;
    if (!type.isVenue && typeListing?.status == VenueStatus.live && !shell.acting) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final weekStart = today.subtract(Duration(days: today.weekday - 1));
      final monthStart = DateTime(today.year, today.month);
      typeEarnings = await api
          .earningsBreakdown(from: weekStart.isBefore(monthStart) ? weekStart : monthStart, to: today, type: type)
          .then<EarningsBreakdown?>((e) => e, onError: (_) => null);
    }
    return HomeData(
      venues: venues,
      home: home,
      typeListing: typeListing,
      checklist: checklist,
      type: type,
      typeEarnings: typeEarnings,
    );
  }

  Future<void> _reload() async {
    await PartnerShell.of(context).reload();
  }

  /// BRD §8: an owner whose listing was created by FitKey staff lands on the handover screen to accept it.
  Future<void> _checkHandover() async {
    final session = context.read<PartnerSession>();
    if (session.isActingAsPartner || (session.user?.isFitkeyStaff ?? false)) return;
    try {
      final items = await session.api.pendingAcceptance();
      if (items.isEmpty || !mounted) return;
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => handoverScreen(items)));
      if (mounted) _reload();
    } catch (_) {
      // Not fatal: the owner can still accept from the timeline card.
    }
  }

  String _greeting() {
    final h = DateTime.now().hour;
    return h < 12 ? 'Good morning' : (h < 17 ? 'Good afternoon' : 'Good evening');
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PartnerSession>();
    final user = session.user;
    final shell = PartnerShell.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final staffOwn = (user?.isFitkeyStaff ?? false) && !session.isActingAsPartner;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(16, (shell.acting ? 0 : top) + 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_greeting()}, ${user?.firstName ?? 'Partner'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                ),
                const SizedBox(height: 2),
                Text(
                  formatDayDate(DateTime.now()),
                  style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ],
            ),
          ),
          const PartnerNotificationBell(),
          Tap(
            onTap: () => shell.goTab(ShellTab.account),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: PersonAvatar(name: user?.name, size: 40),
            ),
          ),
        ],
      ),
    );

    return FutureBuilder<HomeData>(
      future: _future,
      builder: (context, snap) {
        final failed = snap.connectionState == ConnectionState.done && snap.hasError;
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              header,
              if (staffOwn) ...[
                const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 0), child: _StaffCard()),
                const Padding(padding: EdgeInsets.fromLTRB(16, 14, 16, 0), child: CommissionPlanCard(compact: true)),
              ] else if (failed)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: ErrorView(error: snap.error!, onRetry: _reload),
                )
              else if (snap.hasData)
                ...(snap.data!.live ? _liveContent(context, snap.data!) : _setupContent(context, snap.data!))
              else
                const _HomeSkeleton(),
            ],
          ),
        );
      },
    );
  }

  // ---- Before anything is live ---------------------------------------------------------------------------

  List<Widget> _setupContent(BuildContext context, HomeData d) {
    final shell = PartnerShell.of(context);
    final type = d.type;
    final VenueStatus status;
    final String? entityId;
    final String name;
    if (type.isVenue) {
      final v = d.setupVenue;
      status = v?.status ?? VenueStatus.draft;
      entityId = v?.id;
      name = v?.name ?? 'your ${type.label.toLowerCase()}';
    } else {
      status = d.typeListing?.status ?? VenueStatus.draft;
      entityId = d.typeListing?.id;
      name = d.typeListing?.listing == null ? 'your ${type.label.toLowerCase()} profile' : d.typeListing!.name;
    }
    final started = entityId != null;

    Future<void> continueListing([int? step]) async {
      if (type.isVenue) {
        final screen = await venueEditorFor(context, entityId, step: step);
        if (screen != null) await shell.open(screen);
      } else {
        await shell.open(typeListingScreen(type));
      }
    }

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: _SetupCard(
          type: type,
          name: name,
          started: started,
          status: status,
          checklist: d.checklist,
          onContinue: continueListing,
        ),
      ),
      if (started && status != VenueStatus.draft)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: AppCard(
            child: ListingStatusTimeline(
              entityType: type.entityType,
              entityId: entityId,
              status: status,
              onFix: continueListing,
              onAccept: () async {
                final ok = await showAgreementSheet(context, entityType: type.entityType, entityId: entityId!);
                if (ok) await _reload();
              },
            ),
          ),
        ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: SectionTitle('Quick actions', subtitle: 'Unlocks when you go live'),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: QuickActionGrid(actions: _actions(context, d, locked: true)),
      ),
      const Padding(padding: EdgeInsets.fromLTRB(16, 20, 16, 0), child: CommissionPlanCard(compact: true)),
      if (type.isVenue && d.venues.length > 1) ..._venueList(context, d.venues),
    ];
  }

  // ---- Live ----------------------------------------------------------------------------------------------

  List<Widget> _liveContent(BuildContext context, HomeData d) {
    final h = d.home;
    final shell = PartnerShell.of(context);
    final liveVenues = d.venues.where((v) => v.status == VenueStatus.live).toList();
    return [
      if (d.type.isVenue || d.typeEarnings != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: shell.acting || (d.type.isVenue ? h == null : d.typeEarnings == null)
              ? _CheckinsHero(
                  today: d.venues.fold(0, (s, v) => s + v.todayCheckins),
                  month: d.venues.fold(0, (s, v) => s + v.monthCheckins),
                )
              : d.type.isVenue
              ? _EarningsHero(
                  today: h!.todayPaise,
                  week: h.weekPaise,
                  month: h.monthPaise,
                  bySource: h.bySource,
                  onTap: () => shell.goTab(ShellTab.earn),
                )
              : _typeHero(d.typeEarnings!, () => shell.goTab(ShellTab.earn)),
        ),
      if (d.type.isVenue) ...[
        const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SectionTitle("Today's summary")),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _TodayGrid(
            checkins: h?.checkins ?? d.venues.fold(0, (s, v) => s + v.todayCheckins),
            bookings: h?.bookings,
            pending: h?.pendingRequests,
            renewals: shell.acting ? null : h?.renewalsDue,
            onCheckins: d.type.isVenue
                ? () => forLiveVenue(
                    context,
                    d.venues,
                    title: 'Attendance for…',
                    build: (v) => AttendanceScreen(venueId: v.id, venueName: v.name),
                  )
                : null,
            onPending: d.type.isVenue
                ? () => forLiveVenue(
                    context,
                    d.venues,
                    title: 'Booking requests for…',
                    build: (v) => SlotBoardScreen(venueId: v.id, venueName: v.name, initialTab: 1),
                  )
                : null,
            onRenewals: d.type.isVenue && !shell.acting
                ? () => forLiveVenue(
                    context,
                    d.venues,
                    title: 'Renewals due at…',
                    build: (v) =>
                        MemberRegisterScreen(venueId: v.id, venueName: v.name, initialStatus: MemberStatus.expiring),
                  )
                : null,
          ),
        ),
      ],
      const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SectionTitle('Quick actions')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: QuickActionGrid(actions: _actions(context, d, locked: false)),
      ),
      if (!shell.acting)
        const Padding(padding: EdgeInsets.fromLTRB(16, 20, 16, 0), child: CommissionPlanCard(compact: true)),
      if (d.type.isVenue && (d.venues.length > 1 || liveVenues.isEmpty)) ..._venueList(context, d.venues),
    ];
  }

  List<Widget> _venueList(BuildContext context, List<VenueListItem> venues) {
    final shell = PartnerShell.of(context);
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SectionTitle('Your venues', subtitle: '${venues.length} listing${venues.length == 1 ? '' : 's'}'),
      ),
      for (final v in venues)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: VenueCard(
            venue: v,
            onTap: () => shell.open(VenueOverviewScreen(venueId: v.id)),
            onShowQr: v.status == VenueStatus.live
                ? () => shell.open(CheckinCodeScreen(venueId: v.id, venueName: v.name))
                : null,
          ),
        ),
    ];
  }

  /// Type-aware quick actions (BRD §9 / §10.4). [locked] = before go-live.
  List<QuickAction> _actions(BuildContext context, HomeData d, {required bool locked}) {
    final shell = PartnerShell.of(context);
    final venues = d.venues;
    QuickAction a(IconData i, String l, Color c, VoidCallback f) => QuickAction(i, l, c, f, locked: locked);
    void venueTool(String title, Widget Function(VenueListItem v) build) =>
        forLiveVenue(context, venues, title: title, build: build);

    return switch (d.type) {
      PartnerType.trainer => [
        a(
          Icons.calendar_month_rounded,
          'Sessions',
          AppColors.teal,
          () => shell.open(const PartnerTrainerScreen(initialTab: 1)),
        ),
        a(Icons.groups_rounded, 'Clients', AppColors.blue, () => shell.open(const TrainerClientsScreen())),
        a(Icons.star_rounded, 'Ratings', AppColors.amber, () => shell.open(const PartnerRatingsScreen(trainer: true))),
        a(Icons.event_rounded, 'Events', AppColors.purple, () => shell.open(const PartnerEventsScreen())),
        a(Icons.badge_rounded, 'Profile', AppColors.pink, () => shell.open(const PartnerTrainerScreen(initialTab: 2))),
        if (!shell.acting)
          a(Icons.account_balance_wallet_rounded, 'Earnings', AppColors.green, () => shell.goTab(ShellTab.earn)),
      ],
      PartnerType.storeSeller => [
        a(
          Icons.receipt_long_rounded,
          'Orders',
          AppColors.blue,
          () => shell.open(const VendorPortalScreen(initialTab: 1)),
        ),
        a(Icons.inventory_2_rounded, 'Products', AppColors.teal, () => shell.open(const VendorPortalScreen())),
        a(
          Icons.warning_amber_rounded,
          'Low stock',
          AppColors.amber,
          () => shell.open(const StoreStockScreen(lowStockOnly: true)),
        ),
        a(Icons.assignment_return_rounded, 'Returns', AppColors.red, () => shell.open(const StoreReturnsScreen())),
        a(Icons.storefront_rounded, 'Store', AppColors.pink, () => shell.open(const VendorPortalScreen(initialTab: 3))),
        if (!shell.acting)
          a(Icons.account_balance_wallet_rounded, 'Earnings', AppColors.green, () => shell.goTab(ShellTab.earn)),
      ],
      PartnerType.clinic => [
        a(Icons.event_note_rounded, 'Appointments', AppColors.blue, () => shell.open(const ClinicAppointmentsScreen())),
        a(
          Icons.people_alt_rounded,
          'Patient queue',
          AppColors.teal,
          () => shell.open(const ClinicAppointmentsScreen(queue: true)),
        ),
        a(Icons.star_rounded, 'Ratings', AppColors.amber, () => shell.open(const PartnerRatingsScreen())),
        if (!shell.acting)
          a(Icons.account_balance_wallet_rounded, 'Earnings', AppColors.green, () => shell.goTab(ShellTab.earn)),
      ],
      PartnerType.chemist => [
        a(Icons.receipt_long_rounded, 'Orders', AppColors.blue, () => shell.open(const ChemistOrdersScreen())),
        a(
          Icons.local_shipping_rounded,
          'Deliveries',
          AppColors.teal,
          () => shell.open(const ChemistOrdersScreen(deliveriesOnly: true)),
        ),
        a(Icons.star_rounded, 'Ratings', AppColors.amber, () => shell.open(const PartnerRatingsScreen())),
        if (!shell.acting)
          a(Icons.account_balance_wallet_rounded, 'Earnings', AppColors.green, () => shell.goTab(ShellTab.earn)),
      ],
      _ => [
        a(
          Icons.qr_code_2_rounded,
          'Show QR',
          AppColors.primary,
          () => venueTool('Show check-in QR for…', (v) => CheckinCodeScreen(venueId: v.id, venueName: v.name)),
        ),
        a(
          Icons.qr_code_scanner_rounded,
          'Scan check-in',
          AppColors.ink,
          () => venueTool('Scan check-in at…', (v) => ScanCheckinScreen(venueId: v.id, venueName: v.name)),
        ),
        if (!shell.acting)
          a(
            Icons.person_add_alt_1_rounded,
            'Add member',
            AppColors.blue,
            () => venueTool(
              'Add a member to…',
              (v) => MemberRegisterScreen(venueId: v.id, venueName: v.name, openAdd: true),
            ),
          ),
        a(
          Icons.event_available_rounded,
          'Bookings',
          AppColors.teal,
          () => venueTool('Bookings & slots for…', (v) => SlotBoardScreen(venueId: v.id, venueName: v.name)),
        ),
        a(Icons.star_rounded, 'Ratings', AppColors.amber, () => shell.open(const PartnerRatingsScreen())),
        if (locked)
          a(Icons.event_rounded, 'Events', AppColors.purple, () => shell.open(const PartnerEventsScreen()))
        else
          a(
            Icons.insights_rounded,
            'Attendance',
            AppColors.purple,
            () => venueTool('Attendance for…', (v) => AttendanceScreen(venueId: v.id, venueName: v.name)),
          ),
      ],
    };
  }
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

class _StaffCard extends StatelessWidget {
  const _StaffCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      gradient: AppColors.passGradient,
      onTap: () => push(context, staffHomeScreen()),
      child: Row(
        children: [
          const IconBubble(Icons.support_agent_rounded, color: AppColors.lime, size: 48),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FITKEY STAFF',
                  style: TextStyle(
                    color: AppColors.lime,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'List on behalf of a partner',
                  style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 2),
                Text(
                  'Create a listing for a gym or seller; they accept it with an OTP.',
                  style: TextStyle(color: Colors.white70, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward_rounded, color: Colors.white),
        ],
      ),
    );
  }
}

class _SetupCard extends StatelessWidget {
  const _SetupCard({
    required this.type,
    required this.name,
    required this.started,
    required this.status,
    required this.checklist,
    required this.onContinue,
  });

  final PartnerType type;
  final String name;
  final bool started;
  final VenueStatus status;
  final SetupChecklist? checklist;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final pct = started ? (checklist?.percent ?? 0) : 0;
    final editable = status.canSubmit || status == VenueStatus.draft;
    final title = !started
        ? (type.isVenue ? 'List your ${type.label.toLowerCase()}' : 'Set up your ${type.label.toLowerCase()} profile')
        : switch (status) {
            VenueStatus.submitted || VenueStatus.underReview => 'FITKEY is reviewing $name',
            VenueStatus.changesNeeded => 'A few fixes needed',
            VenueStatus.approved => 'Approved — accept to go live',
            VenueStatus.rejected => 'Listing not approved',
            _ => 'Finish $name',
          };
    final subtitle = !started
        ? 'A few steps — details, photos, pricing and documents. FITKEY verifies it, then members walk in.'
        : editable
        ? (checklist?.summary ?? 'Continue where you left off')
        : status == VenueStatus.approved
        ? 'Accept the partner agreement with an OTP to go live.'
        : 'We usually review within 48 hours. We\'ll notify you.';
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBubble(
                started ? statusIcon(status) : Icons.rocket_launch_rounded,
                color: started ? statusColor(status) : AppColors.primary,
                size: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                    ),
                    if (started) ...[const SizedBox(height: 4), StatusPill(status)],
                  ],
                ),
              ),
              if (started && editable)
                Text(
                  '$pct%',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.primary),
                ),
            ],
          ),
          if (started && editable) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: pct / 100,
                minHeight: 8,
                backgroundColor: AppColors.surfaceAlt,
                color: AppColors.primary,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            subtitle,
            style: const TextStyle(color: AppColors.text2, height: 1.4, fontWeight: FontWeight.w600),
          ),
          if (started && editable && (checklist?.missing.isNotEmpty ?? false)) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in checklist!.missing)
                  Tag(m.label, icon: Icons.radio_button_unchecked_rounded, color: AppColors.amber),
              ],
            ),
          ],
          if (!started || editable) ...[
            const SizedBox(height: 16),
            AppButton(
              label: !started
                  ? 'Start listing'
                  : (status == VenueStatus.changesNeeded ? 'Fix and resubmit' : 'Continue listing'),
              icon: Icons.arrow_forward_rounded,
              height: 48,
              onPressed: onContinue,
            ),
          ],
        ],
      ),
    );
  }
}

class _EarningsHero extends StatelessWidget {
  const _EarningsHero({
    required this.today,
    required this.week,
    required this.month,
    required this.bySource,
    required this.onTap,
  });
  final int today;
  final int week;
  final int month;
  final List<SourceAmount> bySource;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sources = bySource.where((s) => s.netPaise != 0).toList();
    final white85 = Colors.white.withValues(alpha: 0.85);
    return Tap(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          gradient: AppColors.primaryGradient,
          borderRadius: BorderRadius.circular(22),
          boxShadow: AppShadows.glow(AppColors.primary),
        ),
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'EARNED TODAY',
                  style: TextStyle(color: white85, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.4),
                ),
                const Spacer(),
                Text(
                  'Details',
                  style: TextStyle(color: white85, fontWeight: FontWeight.w700, fontSize: 12.5),
                ),
                Icon(Icons.chevron_right_rounded, color: white85, size: 18),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              formatPaise(today),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 40,
                fontWeight: FontWeight.w800,
                height: 1.05,
                letterSpacing: -1.2,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _pill('This week', week)),
                const SizedBox(width: 10),
                Expanded(child: _pill('This month', month)),
              ],
            ),
            if (sources.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in sources)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        '${s.label} · ${compactRupees(s.netPaise)}',
                        style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pill(String label, int paise) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(14)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          compactRupees(paise),
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
        ),
        Text(
          label,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

/// Fallback hero when earnings aren't available (server not updated yet, or a staff member is acting).
class _CheckinsHero extends StatelessWidget {
  const _CheckinsHero({required this.today, required this.month});
  final int today;
  final int month;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: BorderRadius.circular(22),
        boxShadow: AppShadows.glow(AppColors.primary),
      ),
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CHECK-INS TODAY',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  formatNumber(today),
                  style: const TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.w800, height: 1.05),
                ),
              ],
            ),
          ),
          Column(
            children: [
              Text(
                formatNumber(month),
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
              ),
              Text(
                'this month',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TodayGrid extends StatelessWidget {
  const _TodayGrid({
    required this.checkins,
    this.bookings,
    this.pending,
    this.renewals,
    this.onCheckins,
    this.onPending,
    this.onRenewals,
  });

  final int checkins;
  final int? bookings;
  final int? pending;
  final int? renewals;
  final VoidCallback? onCheckins;
  final VoidCallback? onPending;
  final VoidCallback? onRenewals;

  @override
  Widget build(BuildContext context) {
    Widget tile(String label, int? v, IconData i, Color c, VoidCallback? onTap) => Expanded(
      child: Tap(
        onTap: onTap,
        child: MetricTile(label: label, value: v == null ? '–' : formatNumber(v), icon: i, color: c),
      ),
    );
    return Column(
      children: [
        Row(
          children: [
            tile('Check-ins', checkins, Icons.login_rounded, AppColors.green, onCheckins),
            const SizedBox(width: 12),
            tile('Bookings', bookings, Icons.event_available_rounded, AppColors.blue, onPending),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            tile('Pending requests', pending, Icons.pending_actions_rounded, AppColors.amber, onPending),
            const SizedBox(width: 12),
            tile('Renewals due', renewals, Icons.autorenew_rounded, AppColors.pink, onRenewals),
          ],
        ),
      ],
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(height: 160, radius: 22),
            SizedBox(height: 28),
            SkeletonBox(height: 18, width: 140),
            SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: SkeletonBox(height: 96, radius: 18)),
                SizedBox(width: 12),
                Expanded(child: SkeletonBox(height: 96, radius: 18)),
                SizedBox(width: 12),
                Expanded(child: SkeletonBox(height: 96, radius: 18)),
              ],
            ),
            SizedBox(height: 16),
            SkeletonBox(height: 180, radius: 20),
          ],
        ),
      ),
    );
  }
}

Widget _typeHero(EarningsBreakdown e, VoidCallback onTap) {
  final p = periodTotals(e.byDay);
  return _EarningsHero(today: p.today, week: p.week, month: p.month, bySource: e.bySource, onTap: onTap);
}
