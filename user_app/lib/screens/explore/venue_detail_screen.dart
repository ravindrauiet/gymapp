import 'package:fitkey_core/fitkey_core.dart' show amenityLabels, formatPaise, formatTimeOfDay;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../../widgets/rating_widgets.dart';
import '../../widgets/venue_card.dart' show isOpenNow;
import '../checkin/checkin_screen.dart';
import '../community/buddy_screens.dart';
import '../plans/plans_screen.dart';

class VenueDetailScreen extends StatefulWidget {
  const VenueDetailScreen({super.key, required this.venueId});

  final String venueId;

  @override
  State<VenueDetailScreen> createState() => _VenueDetailScreenState();
}

class _VenueDetailScreenState extends State<VenueDetailScreen> {
  late Future<({Venue venue, List<PlanRef> plans})> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<Session>().api.venue(widget.venueId);
  }

  void _retry() => setState(() => _future = context.read<Session>().api.venue(widget.venueId));

  Future<void> _open(Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!ok && mounted) toast(context, 'Couldn\'t open that on this device', error: true);
  }

  void _directions(Venue v) {
    final q = v.latitude != null
        ? '${v.latitude},${v.longitude}'
        : Uri.encodeComponent([v.name, v.address, v.area, v.city].whereType<String>().join(', '));
    _open(Uri.parse('https://www.google.com/maps/search/?api=1&query=$q'));
  }

  @override
  Widget build(BuildContext context) {
    final sub = context.watch<Session>().subscription;
    return FutureBuilder(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: AppBar(),
            body: Shimmer(
              child: ListView(physics: const NeverScrollableScrollPhysics(), padding: const EdgeInsets.all(16), children: const [
                SkeletonBox(height: 240, radius: 22),
                SizedBox(height: 20),
                SkeletonBox(height: 24, width: 220),
                SizedBox(height: 10),
                SkeletonBox(height: 14, width: 160),
                SizedBox(height: 24),
                SkeletonBox(height: 120, radius: 18),
              ]),
            ),
          );
        }
        if (snap.hasError) return Scaffold(appBar: AppBar(), body: ErrorView(error: snap.error!, onRetry: _retry));
        final venue = snap.data!.venue;
        final plans = snap.data!.plans;
        final covered = sub != null && sub.categories.any(venue.categories.contains);
        return Scaffold(
          body: CustomScrollView(slivers: [
            SliverAppBar(
              expandedHeight: 300,
              pinned: true,
              stretch: true,
              backgroundColor: AppColors.surface,
              leading: Padding(
                padding: const EdgeInsets.all(8),
                child: CircleAvatar(
                  backgroundColor: Colors.white,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.arrow_back_rounded, color: AppColors.ink, size: 22),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ),
              title: Text(venue.name, style: const TextStyle(fontSize: 17)),
              flexibleSpace: FlexibleSpaceBar(
                collapseMode: CollapseMode.parallax,
                background: _Gallery(venue: venue),
              ),
            ),
            SliverToBoxAdapter(child: _Body(
              venue: venue,
              plans: plans,
              covered: covered,
              onDirections: () => _directions(venue),
              onCall: venue.contactPhone == null ? null : () => _open(Uri.parse('tel:${venue.contactPhone}')),
            )),
          ]),
          bottomNavigationBar: BottomActionBar(
            leading: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(covered ? 'Included in' : 'From',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
              Text(
                covered
                    ? sub.planName
                    : plans.isEmpty
                        ? 'FitKey Pass'
                        : '${formatPaise(plans.map((p) => p.pricePaise).reduce((a, b) => a < b ? a : b))}/pass',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
            ]),
            child: covered
                ? AppButton(
                    label: 'Check in here',
                    icon: Icons.qr_code_scanner_rounded,
                    onPressed: () => push(context, CheckinScreen(venueId: venue.id, venueName: venue.name)),
                  )
                : AppButton(
                    label: 'Get a pass',
                    icon: Icons.key_rounded,
                    color: AppColors.ink,
                    onPressed: () => push(context, const PlansScreen()),
                  ),
          ),
        );
      },
    );
  }
}

class _Gallery extends StatefulWidget {
  const _Gallery({required this.venue});
  final Venue venue;

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    final fallback = venueVisual(v.categories.isEmpty ? '' : v.categories.first).image;
    final photos = v.photos;
    return Stack(fit: StackFit.expand, children: [
      if (photos.isEmpty)
        Image.asset(fallback, fit: BoxFit.cover)
      else
        PageView.builder(
          itemCount: photos.length,
          onPageChanged: (i) => setState(() => _i = i),
          itemBuilder: (_, i) => NetImage(photos[i], fallback: fallback),
        ),
      const IgnorePointer(child: PhotoScrim(strength: 0.5)),
      if (photos.length > 1)
        Positioned(
          right: 14,
          bottom: 40,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
            child: Row(children: [
              const Icon(Icons.photo_library_rounded, color: Colors.white, size: 14),
              const SizedBox(width: 5),
              Text('${_i + 1}/${photos.length}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
            ]),
          ),
        ),
      // White lip so the content card appears to slide over the photo.
      Positioned(
        left: 0,
        right: 0,
        bottom: -1,
        child: Container(
          height: 24,
          decoration: const BoxDecoration(
            color: AppColors.bg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
        ),
      ),
    ]);
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.venue, required this.plans, required this.covered, required this.onDirections, this.onCall});

  final Venue venue;
  final List<PlanRef> plans;
  final bool covered;
  final VoidCallback onDirections;
  final VoidCallback? onCall;

  @override
  Widget build(BuildContext context) {
    final open = isOpenNow(venue.opensAt, venue.closesAt);
    final location = venue.address ?? [venue.area, venue.city].whereType<String>().join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in venue.categories)
            Tag(venueVisual(c).label, color: venueVisual(c).color, icon: venueVisual(c).icon),
        ]),
        const SizedBox(height: 10),
        Text(venue.name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.7, height: 1.15)),
        const SizedBox(height: 6),
        Text(location, style: const TextStyle(color: AppColors.text2, fontSize: 14, height: 1.4)),
        if (venue.ratingCount != null) ...[
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: RatingBadge(avg: venue.ratingAvg, count: venue.ratingCount)),
        ],
        const SizedBox(height: 10),
        Row(children: [
          if (open != null) ...[
            Text(open ? 'Open now' : 'Closed now',
                style: TextStyle(color: open ? AppColors.green : AppColors.red, fontWeight: FontWeight.w800)),
            const Text('  •  ', style: TextStyle(color: AppColors.text3)),
          ],
          Text('${formatTimeOfDay(venue.opensAt)} – ${formatTimeOfDay(venue.closesAt)}',
              style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _Action(Icons.directions_rounded, 'Directions', onDirections)),
          const SizedBox(width: 10),
          Expanded(child: _Action(Icons.call_rounded, 'Call', onCall)),
          const SizedBox(width: 10),
          Expanded(
            child: _Action(
              Icons.people_alt_rounded,
              'Find buddy',
              () => push(
                context,
                CreateBuddyPostScreen(
                  initialVenue: VenueSummary.fromJson({
                    'id': venue.id,
                    'name': venue.name,
                    'area': venue.area,
                    'city': venue.city,
                    'categories': venue.categories,
                  }),
                ),
              ),
            ),
          ),
        ]),
        if (covered) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(16)),
            child: const Row(children: [
              Icon(Icons.verified_rounded, color: AppColors.green),
              SizedBox(width: 10),
              Expanded(
                child: Text('Your FitKey Pass covers this venue — just scan the QR at the front desk.',
                    style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF0E6B49), height: 1.35)),
              ),
            ]),
          ),
        ],
        if ((venue.description ?? '').isNotEmpty) ...[
          const SectionTitle('About'),
          Text(venue.description!, style: const TextStyle(height: 1.55, color: AppColors.text2, fontSize: 14.5)),
        ],
        const SectionTitle('Ratings', subtitle: 'From members who checked in here'),
        RatingSummaryCard(
          targetType: 'venue',
          targetId: venue.id,
          name: venue.name,
          photoUrl: venue.photos.isEmpty ? null : venue.photos.first,
          fallbackImage: venueVisual(venue.categories.isEmpty ? '' : venue.categories.first).image,
        ),
        const SectionTitle('Timings'),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const IconBubble(Icons.schedule_rounded, size: 40),
              const SizedBox(width: 12),
              Text('${formatTimeOfDay(venue.opensAt)} – ${formatTimeOfDay(venue.closesAt)}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ]),
            const SizedBox(height: 14),
            _OpenDays(days: venue.openDays),
          ]),
        ),
        if (venue.amenities.isNotEmpty || venue.trainerAvailable) ...[
          const SectionTitle('Amenities'),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.15,
            children: [
              if (venue.trainerAvailable) const _Amenity(Icons.sports_rounded, 'Trainer'),
              for (final a in venue.amenities)
                _Amenity((amenityLabels[a]?.$2) ?? Icons.check_rounded, amenityLabels[a]?.$1 ?? a),
            ],
          ),
        ],
        if (venue.equipment.isNotEmpty) ...[
          const SectionTitle('Equipment'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in venue.equipment)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.line),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.check_circle_rounded, size: 16, color: AppColors.green),
                  const SizedBox(width: 6),
                  Text(e, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                ]),
              ),
          ]),
        ],
        if (plans.isNotEmpty) ...[
          const SectionTitle('Passes that include this venue'),
          for (final p in plans)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AppCard(
                onTap: () => push(context, const PlansScreen()),
                child: Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(gradient: AppColors.passGradient, borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.key_rounded, color: AppColors.lime),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      Text('${p.durationDays} days of access',
                          style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                    ]),
                  ),
                  Text(formatPaise(p.pricePaise), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
                ]),
              ),
            ),
        ],
        if (venue.contactPhone != null) ...[
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: venue.contactPhone!));
                toast(context, 'Phone number copied', icon: Icons.copy_rounded);
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: Text('Front desk: ${venue.contactPhone}'),
            ),
          ),
        ],
      ]),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tap(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(children: [
          Icon(icon, color: enabled ? AppColors.primary : AppColors.text3),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 12.5, color: enabled ? AppColors.text : AppColors.text3)),
        ]),
      ),
    );
  }
}

class _Amenity extends StatelessWidget {
  const _Amenity(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), boxShadow: AppShadows.soft),
      padding: const EdgeInsets.all(8),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: AppColors.primary, size: 24),
        const SizedBox(height: 6),
        Text(label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _OpenDays extends StatelessWidget {
  const _OpenDays({required this.days});
  final List<String> days;

  @override
  Widget build(BuildContext context) {
    const all = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    final today = all[DateTime.now().weekday - 1];
    return Row(children: [
      for (final d in all)
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: days.contains(d) ? (d == today ? AppColors.primary : AppColors.primarySoft) : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              d[0].toUpperCase() + d.substring(1, 2),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
                color: days.contains(d) ? (d == today ? Colors.white : AppColors.primary) : AppColors.text3,
                decoration: days.contains(d) ? null : TextDecoration.lineThrough,
              ),
            ),
          ),
        ),
    ]);
  }
}
