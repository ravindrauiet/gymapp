import 'package:fitkey_core/fitkey_core.dart' show amenityLabels, formatTimeOfDay;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../../widgets/status.dart';
import '../attendance/attendance_screen.dart';
import '../checkin/checkin_code_screen.dart';
import '../events/partner_events_screen.dart';
import '../ratings/partner_ratings_screen.dart';
import 'venue_editor_screen.dart';

class VenueOverviewScreen extends StatefulWidget {
  const VenueOverviewScreen({super.key, required this.venueId});

  final String venueId;

  @override
  State<VenueOverviewScreen> createState() => _VenueOverviewScreenState();
}

class _VenueOverviewScreenState extends State<VenueOverviewScreen> {
  late Future<PartnerVenue> _future = _load();
  bool _busy = false;

  Future<PartnerVenue> _load() => context.read<PartnerSession>().api.venue(widget.venueId);

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

  Future<void> _submit(PartnerVenue v) async {
    setState(() => _busy = true);
    try {
      await context.read<PartnerSession>().api.submitVenue(v.id!);
      if (!mounted) return;
      toast(context, 'Submitted for review — we usually respond within 2 working days');
      await _reload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
    return FutureBuilder<PartnerVenue>(
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

  Widget _body(PartnerVenue v) {
    final missing = _missing(v);
    final visual = venueVisual(v.categories.firstOrNull ?? '');
    final live = v.status == VenueStatus.live;

    final Widget primary;
    if (live) {
      primary = AppButton(
        label: 'Show check-in QR',
        icon: Icons.qr_code_2_rounded,
        onPressed: () => _push(CheckinCodeScreen(venueId: v.id!, venueName: v.name)),
      );
    } else if (v.status.canSubmit) {
      primary = AppButton(
        label: missing.isEmpty ? 'Submit for review' : 'Complete listing to submit',
        icon: missing.isEmpty ? Icons.send_rounded : Icons.edit_rounded,
        busy: _busy,
        onPressed: missing.isEmpty ? () => _submit(v) : () => _push(VenueEditorScreen(existing: v)),
      );
    } else {
      primary = AppButton(
        label: 'Edit listing',
        icon: Icons.edit_rounded,
        color: AppColors.ink,
        onPressed: () => _push(VenueEditorScreen(existing: v)),
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
                  onTap: () => _push(VenueEditorScreen(existing: v)),
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
                StatusTimeline(status: v.status, reviewNote: v.reviewNote),
                if (v.status.canSubmit && missing.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: AppColors.amberSoft, borderRadius: BorderRadius.circular(14)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.checklist_rounded, color: AppColors.amber, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('Before submitting: ${missing.join(' · ')}',
                            style: const TextStyle(color: Color(0xFF9A5B00), fontWeight: FontWeight.w700, height: 1.4)),
                      ),
                    ]),
                  ),
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
                      icon: Icons.edit_note_rounded,
                      color: AppColors.primary,
                      title: 'Edit listing',
                      subtitle: 'Photos, hours, facilities',
                      onTap: () => _push(VenueEditorScreen(existing: v)),
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
                    _detail(Icons.schedule_rounded, AppColors.primary, 'Timings',
                        '${formatTimeOfDay('${v.opensAt}:00')} – ${formatTimeOfDay('${v.closesAt}:00')} · ${_days(v.openDays)}'),
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

  static const _dayOrder = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  static const _dayShort = {'mon': 'Mon', 'tue': 'Tue', 'wed': 'Wed', 'thu': 'Thu', 'fri': 'Fri', 'sat': 'Sat', 'sun': 'Sun'};

  String _days(List<String> days) {
    if (days.length == 7) return 'Open all week';
    if (days.isEmpty) return 'No days set';
    final sorted = _dayOrder.where(days.contains).map((d) => _dayShort[d]!).toList();
    return sorted.join(', ');
  }

  List<String> _missing(PartnerVenue v) => [
        if (v.photos.length < 4) 'add ${4 - v.photos.length} more photo${v.photos.length == 3 ? '' : 's'}',
        if (v.categories.isEmpty) 'choose a category',
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
