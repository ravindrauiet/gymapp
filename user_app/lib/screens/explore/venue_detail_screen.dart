import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
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
  int _photo = 0;

  @override
  void initState() {
    super.initState();
    _future = context.read<Session>().api.venue(widget.venueId);
  }

  void _retry() => setState(() => _future = context.read<Session>().api.venue(widget.venueId));

  Future<void> _openMaps(Venue v) async {
    final query = v.latitude != null ? '${v.latitude},${v.longitude}' : Uri.encodeComponent('${v.name} ${v.address}');
    await launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=$query'),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Scaffold(appBar: AppBar(), body: ErrorState(message: errorMessage(snap.error!), onRetry: _retry));
          }
          final venue = snap.data!.venue;
          final plans = snap.data!.plans;
          return CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 280,
                pinned: true,
                flexibleSpace: FlexibleSpaceBar(background: _gallery(venue)),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
                sliver: SliverList.list(children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: venue.categories.map((c) => CategoryPill(venueCategory(c))).toList(),
                  ),
                  const SizedBox(height: 12),
                  Text(venue.name, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () => _openMaps(venue),
                    child: Row(children: [
                      const Icon(Icons.place_outlined, size: 18, color: FkColors.lime),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(venue.address ?? [venue.area, venue.city].whereType<String>().join(', '),
                            style: const TextStyle(color: FkColors.textSecondary)),
                      ),
                      const Text('Directions', style: TextStyle(color: FkColors.lime, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                  if (venue.description != null) ...[
                    const SizedBox(height: 16),
                    Text(venue.description!, style: const TextStyle(height: 1.5)),
                  ],
                  const SectionHeader('Timings'),
                  _InfoRow(
                    icon: Icons.schedule,
                    title: '${formatTimeOfDay(venue.opensAt)} – ${formatTimeOfDay(venue.closesAt)}',
                    subtitle: _days(venue.openDays),
                  ),
                  if (venue.contactPhone != null)
                    _InfoRow(
                      icon: Icons.call_outlined,
                      title: venue.contactPhone!,
                      subtitle: 'Tap to call',
                      onTap: () => launchUrl(Uri.parse('tel:${venue.contactPhone}')),
                    ),
                  const SectionHeader('Facilities'),
                  _InfoRow(
                    icon: Icons.sports,
                    title: venue.trainerAvailable ? 'Trainer available' : 'No trainer on site',
                    subtitle: venue.trainerAvailable ? 'Ask at the front desk' : 'Self-guided workouts',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: venue.amenities.map((a) {
                      final (label, icon) = amenityLabels[a] ?? (a, Icons.check);
                      return Chip(avatar: Icon(icon, size: 16, color: FkColors.lime), label: Text(label));
                    }).toList(),
                  ),
                  if (venue.equipment.isNotEmpty) ...[
                    const SectionHeader('Equipment'),
                    ...venue.equipment.map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(children: [
                            const Icon(Icons.check_circle, size: 18, color: FkColors.lime),
                            const SizedBox(width: 10),
                            Expanded(child: Text(e)),
                          ]),
                        )),
                  ],
                  const SectionHeader('Included in'),
                  ...plans.map((p) => Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: const Icon(Icons.key, color: FkColors.lime),
                          title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text('${formatPaise(p.pricePaise)} / ${p.durationDays} days'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlansScreen())),
                        ),
                      )),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.people_alt_outlined),
                    label: const Text('Find a gym buddy here'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CreateBuddyPostScreen(
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
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: FutureBuilder(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const SizedBox.shrink();
          final venue = snap.data!.venue;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: FilledButton.icon(
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Check in here'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => CheckinScreen(venueId: venue.id, venueName: venue.name)),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _gallery(Venue venue) {
    final photos = venue.photos;
    final category = venue.categories.isEmpty ? null : venue.categories.first;
    if (photos.isEmpty) return VenueImage(url: null, category: category);
    return Stack(fit: StackFit.expand, children: [
      PageView.builder(
        itemCount: photos.length,
        onPageChanged: (i) => setState(() => _photo = i),
        itemBuilder: (_, i) => VenueImage(url: photos[i], category: category),
      ),
      Positioned(
        bottom: 14,
        left: 0,
        right: 0,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            photos.length,
            (i) => AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == _photo ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == _photo ? FkColors.lime : Colors.white54,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  String _days(List<String> days) {
    const all = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    if (days.length == 7) return 'Open all week';
    final closed = all.where((d) => !days.contains(d)).map((d) => d[0].toUpperCase() + d.substring(1));
    return 'Closed on ${closed.join(', ')}';
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.title, this.subtitle, this.onTap});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: FkColors.surfaceHigh, borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: FkColors.lime, size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(color: FkColors.textSecondary)),
    );
  }
}
