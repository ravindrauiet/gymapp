import 'package:fitkey_core/fitkey_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../widgets/status.dart';
import '../auth/profile_screen.dart';
import '../checkin/checkin_code_screen.dart';
import '../venue/venue_editor_screen.dart';
import '../venue/venue_overview_screen.dart';

/// Partner home: all my venues, today's check-ins, quick access to the front-desk QR.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<List<VenueListItem>> _future = _load();

  Future<List<VenueListItem>> _load() => context.read<PartnerSession>().api.venues();

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    await f;
  }

  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<PartnerSession>().user;
    return Scaffold(
      appBar: AppBar(
        title: const FitKeyLogo(size: 30, tag: 'PARTNER'),
        actions: [
          IconButton(
            tooltip: 'Account',
            icon: Avatar(name: user?.name, radius: 16),
            onPressed: () => _open(const ProfileScreen(editing: true)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: FkColors.lime,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_business),
        label: const Text('Add venue', style: TextStyle(fontWeight: FontWeight.w800)),
        onPressed: () => _open(const VenueEditorScreen()),
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<List<VenueListItem>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return ListView(children: [ErrorState(message: errorMessage(snap.error!), onRetry: _reload)]);
            }
            final venues = snap.data!;
            final live = venues.where((v) => v.status == VenueStatus.live).toList();
            final today = live.fold<int>(0, (s, v) => s + v.todayCheckins);
            final month = live.fold<int>(0, (s, v) => s + v.monthCheckins);

            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
              children: [
                Text('Hello ${user?.firstName ?? ''} 👋', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(formatDayDate(DateTime.now()), style: const TextStyle(color: FkColors.textSecondary)),
                const SizedBox(height: 20),
                if (venues.isEmpty)
                  EmptyState(
                    icon: Icons.storefront,
                    title: 'List your first venue',
                    message: 'Add your categories, photos, timings and facilities. '
                        'Once FITKEY verifies it, members can start checking in.',
                    action: FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(220, 48)),
                      onPressed: () => _open(const VenueEditorScreen()),
                      child: const Text('Start listing'),
                    ),
                  )
                else ...[
                  Row(children: [
                    Expanded(
                      child: StatTile(label: 'Check-ins today', value: '$today', icon: Icons.login),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: StatTile(
                          label: 'This month', value: '$month', icon: Icons.calendar_month, color: FkColors.sky),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: StatTile(
                          label: 'Live venues',
                          value: '${live.length}/${venues.length}',
                          icon: Icons.storefront,
                          color: FkColors.orange),
                    ),
                  ]),
                  if (live.length == 1) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      icon: const Icon(Icons.qr_code_2),
                      label: const Text('Show check-in QR'),
                      onPressed: () => _open(CheckinCodeScreen(venueId: live.first.id, venueName: live.first.name)),
                    ),
                  ],
                  const SectionHeader('Your venues'),
                  ...venues.map((v) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _VenueTile(
                          venue: v,
                          onTap: () => _open(VenueOverviewScreen(venueId: v.id)),
                          onShowQr: v.status == VenueStatus.live
                              ? () => _open(CheckinCodeScreen(venueId: v.id, venueName: v.name))
                              : null,
                        ),
                      )),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _VenueTile extends StatelessWidget {
  const _VenueTile({required this.venue, required this.onTap, this.onShowQr});

  final VenueListItem venue;
  final VoidCallback onTap;
  final VoidCallback? onShowQr;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            SizedBox(
              width: 72,
              height: 72,
              child: VenueImage(
                url: venue.coverPhoto,
                category: venue.categories.firstOrNull,
                height: 72,
                borderRadius: 12,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(venue.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(venue.location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
                const SizedBox(height: 8),
                Row(children: [
                  StatusPill(venue.status),
                  const SizedBox(width: 8),
                  if (venue.status == VenueStatus.live)
                    Text('${venue.todayCheckins} today',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ]),
            ),
            if (onShowQr != null)
              IconButton.filledTonal(tooltip: 'Check-in QR', onPressed: onShowQr, icon: const Icon(Icons.qr_code_2))
            else
              const Icon(Icons.chevron_right, color: FkColors.textSecondary),
          ]),
        ),
      ),
    );
  }
}
