import 'package:fitkey_core/fitkey_core.dart' show amenityLabels, formatPaise;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/listing_api.dart';
import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../../widgets/agreement_sheet.dart';
import '../../widgets/commission_plan_card.dart';
import '../../widgets/listing/listing_rules.dart';
import '../../widgets/status.dart';
import '../../widgets/status_timeline.dart';
import '../attendance/attendance_screen.dart';
import '../bookings/partner_bookings_screen.dart';
import '../checkin/checkin_code_screen.dart';
import '../events/partner_events_screen.dart';
import '../memberships/members_screen.dart';
import '../memberships/membership_plans_screen.dart';
import '../memberships/partner_earnings_screen.dart';
import '../ratings/partner_ratings_screen.dart';
import 'venue_editor_screen.dart';

class VenueOverviewScreen extends StatefulWidget {
  const VenueOverviewScreen({super.key, required this.venueId});

  final String venueId;

  @override
  State<VenueOverviewScreen> createState() => _VenueOverviewScreenState();
}

class _VenueOverviewScreenState extends State<VenueOverviewScreen> {
  late Future<VenueListing> _future = _load();
  bool _busy = false;

  Future<VenueListing> _load() => context.read<PartnerSession>().api.venueListing(widget.venueId);

  Future<void> _reload() async {
    if (!mounted) return;
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // Shown by the error state.
    }
  }

  /// Opens the listing wizard on a 1-based step (fixes from "changes needed", checklist items, submit = 10).
  Future<void> _edit(PartnerVenue v, {int? step}) => _push(VenueEditorScreen(existing: v, initialStep: step));

  /// Approved listing waiting for the owner's OTP acceptance (assisted listing handover).
  Future<void> _accept(PartnerVenue v) async {
    final ok = await showAgreementSheet(context, entityType: 'venue', entityId: v.id!);
    if (!ok || !mounted) return;
    toast(context, 'Agreement accepted', icon: Icons.verified_rounded);
    await _reload();
  }

  Future<void> _delete(PartnerVenue v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${v.name}?'),
        content: const Text('This listing will be removed permanently.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<PartnerSession>().api.deleteVenue(v.id!);
      if (!mounted) return;
      toast(context, 'Listing deleted');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        toast(context, friendlyError(e), error: true);
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _push(Widget screen) async {
    await push<void>(context, screen);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<VenueListing>(
      future: _future,
      builder: (context, snap) {
        final failed = snap.connectionState == ConnectionState.done && snap.hasError;
        if (failed) {
          return Scaffold(appBar: AppBar(title: const Text('Venue')), body: ErrorView(error: snap.error!, onRetry: _reload));
        }
        if (!snap.hasData) {
          return Scaffold(
            appBar: AppBar(),
            body: Shimmer(
              child: ListView(padding: const EdgeInsets.all(16), children: const [
                SkeletonBox(height: 220, radius: 22),
                SizedBox(height: 16),
                SkeletonBox(height: 24, width: 220),
                SizedBox(height: 10),
                SkeletonBox(height: 14, width: 160),
                SizedBox(height: 20),
                SkeletonBox(height: 150, radius: 20),
              ]),
            ),
          );
        }
        return _body(snap.data!);
      },
    );
  }

  Widget _body(VenueListing listing) {
    final v = listing.venue;
    final checklist = listing.checklist;
    final missing = checklist?.missing ?? _missing(v);
    final firstMissingStep = missing.isEmpty ? null : missing.first.step;
    final schedule = WeekSchedule.fromVenue(v);
    final visual = venueVisual(v.categories.firstOrNull ?? '');
    final live = v.status == VenueStatus.live;

    final Widget primary;
    if (live) {
      primary = AppButton(
        label: 'Show check-in QR',
        icon: Icons.qr_code_2_rounded,
        onPressed: () => _push(CheckinCodeScreen(venueId: v.id!, venueName: v.name)),
      );
    } else if (v.status == VenueStatus.approved && v.partnerAcceptedAt == null) {
      primary = AppButton(
        label: 'Accept agreement & go live',
        icon: Icons.verified_user_rounded,
        color: AppColors.green,
        onPressed: () => _accept(v),
      );
    } else if (v.status.canSubmit) {
      primary = AppButton(
        label: missing.isEmpty ? 'Review & submit' : 'Continue listing',
        icon: missing.isEmpty ? Icons.send_rounded : Icons.edit_rounded,
        busy: _busy,
        onPressed: () => _edit(v, step: missing.isEmpty ? 10 : firstMissingStep),
      );
    } else {
      primary = AppButton(
        label: 'Edit listing',
        icon: Icons.edit_rounded,
        color: AppColors.ink,
        onPressed: () => _edit(v),
      );
    }

    return Scaffold(
      bottomNavigationBar: BottomActionBar(child: primary),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 250,
              backgroundColor: AppColors.surface,
              leading: Padding(
                padding: const EdgeInsets.all(8),
                child: _CircleBtn(icon: Icons.arrow_back_rounded, onTap: () => Navigator.maybePop(context)),
              ),
              actions: [
                _CircleBtn(
                  icon: Icons.edit_rounded,
                  tooltip: 'Edit listing',
                  onTap: () => _edit(v),
                ),
                const SizedBox(width: 10),
              ],
              flexibleSpace: FlexibleSpaceBar(
                collapseMode: CollapseMode.parallax,
                background: Stack(fit: StackFit.expand, children: [
                  NetImage(v.photos.firstOrNull, fallback: visual.image),
                  const PhotoScrim(strength: 0.6),
                  Positioned(
                    left: 16,
                    bottom: 16,
                    right: 16,
                    child: Row(children: [
                      StatusPill(v.status, onPhoto: true),
                      const Spacer(),
                      if (v.photos.length > 1)
                        Tag('${v.photos.length} photos',
                            icon: Icons.photo_library_rounded,
                            color: Colors.white,
                            bg: Colors.black.withValues(alpha: 0.45)),
                    ]),
                  ),
                ]),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              sliver: SliverList.list(children: [
                Text(v.name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                const SizedBox(height: 4),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.place_rounded, size: 16, color: AppColors.text3),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text([v.address, v.area, v.city].where((s) => s.isNotEmpty).join(', '),
                        style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w500, height: 1.35)),
                  ),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final c in v.categories)
                    Tag(venueVisual(c).label, icon: venueVisual(c).icon, color: venueVisual(c).color),
                  if (v.ratingAvg != null && v.ratingCount > 0)
                    Tag('${v.ratingAvg!.toStringAsFixed(1)} ★ · ${v.ratingCount}', color: AppColors.amber),
                ]),
                const SizedBox(height: 18),
                if (v.status == VenueStatus.draft)
                  _ChecklistCard(
                    percent: checklist?.percent ?? (missing.isEmpty ? 100 : 0),
                    missing: missing,
                    onStep: (step) => _edit(v, step: step),
                  )
                else ...[
                  ListingStatusTimeline(
                    entityType: 'venue',
                    entityId: v.id!,
                    status: v.status,
                    onFix: (step) => _edit(v, step: step),
                    onAccept: v.partnerAcceptedAt == null ? () => _accept(v) : null,
                  ),
                  if (v.status.canSubmit && missing.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _ChecklistCard(
                      percent: checklist?.percent ?? 0,
                      missing: missing,
                      onStep: (step) => _edit(v, step: step),
                    ),
                  ],
                ],
                if (v.status != VenueStatus.live) ...[
                  const SizedBox(height: 12),
                  const CommissionPlanCard(compact: true),
                ],
                const SectionTitle('Manage'),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.9,
                  children: [
                    _ManageTile(
                      icon: Icons.insights_rounded,
                      color: AppColors.blue,
                      title: 'Attendance',
                      subtitle: live ? 'Daily & monthly' : 'Once live',
                      onTap: live
                          ? () => _push(AttendanceScreen(venueId: v.id!, venueName: v.name))
                          : () => toast(context, 'Attendance starts once your venue is live', icon: Icons.info_outline_rounded),
                    ),
                    _ManageTile(
                      icon: Icons.event_rounded,
                      color: AppColors.purple,
                      title: 'Events',
                      subtitle: 'Classes & meetups',
                      onTap: () => _push(PartnerEventsScreen(venueId: v.id)),
                    ),
                    _ManageTile(
                      icon: Icons.star_rounded,
                      color: AppColors.amber,
                      title: 'Ratings',
                      subtitle: v.ratingCount > 0 ? '${v.ratingCount} reviews' : 'Member feedback',
                      onTap: () => _push(PartnerRatingsScreen(venueId: v.id)),
                    ),
                    _ManageTile(
                      icon: Icons.card_membership_rounded,
                      color: AppColors.pink,
                      title: 'Membership plans',
                      subtitle: 'Sell your own plans',
                      onTap: () => _push(MembershipPlansScreen(venueId: v.id!, venueName: v.name)),
                    ),
                    _ManageTile(
                      icon: Icons.groups_rounded,
                      color: AppColors.teal,
                      title: 'Members',
                      subtitle: 'Yours & FitKey pass',
                      onTap: () => _push(MembersScreen(venueId: v.id!, venueName: v.name)),
                    ),
                    _ManageTile(
                      icon: Icons.event_available_rounded,
                      color: AppColors.blue,
                      title: 'Bookings & slots',
                      subtitle: live ? 'Slots, check-ins' : 'Once live',
                      onTap: live
                          ? () => _push(PartnerBookingsScreen(venueId: v.id!, venueName: v.name))
                          : () => toast(context, 'Members can book slots once your venue is live', icon: Icons.info_outline_rounded),
                    ),
                    _ManageTile(
                      icon: Icons.account_balance_wallet_rounded,
                      color: AppColors.green,
                      title: 'Earnings',
                      subtitle: 'Payouts & statement',
                      onTap: () => _push(PartnerEarningsScreen(venueId: v.id)),
                    ),
                    _ManageTile(
                      icon: Icons.edit_note_rounded,
                      color: AppColors.primary,
                      title: 'Edit listing',
                      subtitle: 'Photos, hours, facilities',
                      onTap: () => _edit(v),
                    ),
                  ],
                ),
                if (v.photos.length > 1) ...[
                  const SectionTitle('Photos'),
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: v.photos.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (_, i) =>
                          NetImage(v.photos[i], fallback: visual.image, width: 130, height: 96, radius: 14),
                    ),
                  ),
                ],
                const SectionTitle('Listing details'),
                AppCard(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(children: [
                    _detail(Icons.schedule_rounded, AppColors.primary, 'Timings', scheduleSummary(schedule)),
                    if (schedule.ladies.isNotEmpty)
                      _detail(Icons.woman_rounded, AppColors.pink, 'Ladies-only hours',
                          schedule.ladies.map((w) => '${prettyRange(w.start, w.end)} (${prettyDays(w.days)})').join('\n')),
                    _detail(Icons.confirmation_number_rounded, AppColors.purple, 'FitKey pass access',
                        v.fitkeyPassMode == 'blocked' && v.passBlocks.isNotEmpty
                            ? v.passBlocks.map(passBlockLabel).join('\n')
                            : 'Valid at all open hours'),
                    if (v.closures.isNotEmpty)
                      _detail(Icons.event_busy_rounded, AppColors.red, 'Closed dates',
                          v.closures.map((c) => c.wholeDay ? c.closedOn : '${c.closedOn} ${prettyRange(c.slotStart!, c.slotEnd!)}').join(', ')),
                    _detail(Icons.currency_rupee_rounded, AppColors.green, 'FitKey pass payout',
                        v.monthlyFeePaise == null
                            ? 'Monthly fee not set'
                            : '${formatPaise(v.monthlyFeePaise!)}/month · '
                                '${listing.passPayoutPreview != null ? '${formatPaise(listing.passPayoutPreview!.netPaise)} per check-in now' : passPreviewLine(v.monthlyFeePaise!, 1)}'),
                    _detail(Icons.event_seat_rounded, AppColors.blue, 'Slots',
                        '${v.slotMinutes}-min slots · up to ${v.slotCapacity} per slot'
                        '${v.passSlotCap != null ? ' (${v.passSlotCap} FitKey pass)' : ''}'
                        '${v.categories.contains('sports_club') ? ' · ${courtsLine(v.courts, v.sports.firstOrNull, v.slotMinutes)}' : ''}'),
                    if (v.sports.isNotEmpty)
                      _detail(Icons.sports_tennis_rounded, AppColors.green, 'Sports',
                          v.sports.map((s) => sportLabels[s] ?? s).join(', ')),
                    _detail(Icons.sports_rounded, AppColors.teal, 'Trainer', v.trainerAvailable ? 'Available on the floor' : 'Not available'),
                    _detail(Icons.check_circle_outline_rounded, AppColors.green, 'Amenities',
                        v.amenities.isEmpty ? 'None added' : v.amenities.map((a) => amenityLabels[a]?.$1 ?? a).join(', ')),
                    _detail(Icons.fitness_center_rounded, AppColors.purple, 'Equipment',
                        v.equipment.isEmpty ? 'None added' : v.equipment.join(', ')),
                    _detail(Icons.call_outlined, AppColors.blue, 'Contact',
                        _orElse([v.contactPhone, v.contactEmail].where((s) => s.isNotEmpty).join(' · '), 'Not added')),
                    _detail(Icons.my_location_rounded, AppColors.red, 'Map location',
                        v.latitude == null || v.longitude == null
                            ? 'Not pinned'
                            : '${v.latitude!.toStringAsFixed(5)}, ${v.longitude!.toStringAsFixed(5)}',
                        last: true),
                  ]),
                ),
                if (v.status.canDelete) ...[
                  const SizedBox(height: 18),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red),
                    label: const Text('Delete listing', style: TextStyle(color: AppColors.red)),
                    onPressed: _busy ? null : () => _delete(v),
                  ),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }

  static String _orElse(String s, String fallback) => s.isEmpty ? fallback : s;

  /// Fallback when the server sends no checklist (older API).
  List<ChecklistItem> _missing(PartnerVenue v) => [
        if (v.categories.isEmpty) const ChecklistItem(1, 'Choose a category'),
        if (v.description.trim().length < minDescriptionLength) const ChecklistItem(2, 'Describe your venue (40+ characters)'),
        if (v.latitude == null) const ChecklistItem(3, 'Drop a map pin'),
        if (v.photos.length < minPhotosToSubmit) ChecklistItem(5, 'Add ${minPhotosToSubmit - v.photos.length} more photos'),
        if (v.monthlyFeePaise == null || !v.passAccepted) const ChecklistItem(7, 'Set pricing & FitKey pass'),
      ];

  Widget _detail(IconData icon, Color color, String title, String value, {bool last = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: AppColors.line))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconBubble(icon, color: color, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.35)),
            ]),
          ),
        ]),
      );
}

class _CircleBtn extends StatelessWidget {
  const _CircleBtn({required this.icon, required this.onTap, this.tooltip});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = Tap(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: AppShadows.soft),
        child: Icon(icon, size: 20, color: AppColors.text),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

class _ManageTile extends StatelessWidget {
  const _ManageTile({required this.icon, required this.color, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      radius: 18,
      child: Row(children: [
        IconBubble(icon, color: color, size: 40),
        const SizedBox(width: 10),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
            Text(subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: AppColors.text2)),
          ]),
        ),
      ]),
    );
  }
}

/// Setup checklist (percent + what's missing); each item opens the wizard on that step.
class _ChecklistCard extends StatelessWidget {
  const _ChecklistCard({required this.percent, required this.missing, required this.onStep});

  final int percent;
  final List<ChecklistItem> missing;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    final done = missing.isEmpty;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(
            width: 48,
            height: 48,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(
                value: percent / 100,
                strokeWidth: 5,
                color: done ? AppColors.green : AppColors.primary,
                backgroundColor: AppColors.surfaceAlt,
              ),
              Text('$percent%', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(done ? 'Listing complete' : 'Finish your listing',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              Text(
                done ? 'Review and submit — we check new listings within 48 hours.' : '${missing.length} step${missing.length == 1 ? '' : 's'} left before you can submit',
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35),
              ),
            ]),
          ),
        ]),
        if (!done) ...[
          const SizedBox(height: 10),
          for (final m in missing)
            Tap(
              onTap: () => onStep(m.step),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: AppColors.amberSoft, shape: BoxShape.circle),
                    child: Text('${m.step}',
                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Color(0xFF9A5B00))),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (m.hint != null && m.hint!.isNotEmpty)
                        Text(m.hint!, style: const TextStyle(color: AppColors.text3, fontSize: 12)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
                ]),
              ),
            ),
        ],
      ]),
    );
  }
}
