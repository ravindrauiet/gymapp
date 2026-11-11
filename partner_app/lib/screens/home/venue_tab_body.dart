import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../ui/ui.dart';
import 'listing_nav.dart';
import 'shell.dart';

/// Body for venue-based Run / Sell tabs: loads the venue list, shows a switcher when there are several and hands the
/// selected venue to [builder]. Empty state invites the partner to list a venue.
class VenueTabBody extends StatefulWidget {
  const VenueTabBody({super.key, required this.builder});

  final List<Widget> Function(BuildContext context, VenueListItem venue) builder;

  @override
  State<VenueTabBody> createState() => _VenueTabBodyState();
}

class _VenueTabBodyState extends State<VenueTabBody> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final shell = PartnerShell.of(context);
    return FutureBuilder<List<VenueListItem>>(
      future: shell.venues,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 4, itemHeight: 76);
        if (snap.hasError) return ErrorView(error: snap.error!, onRetry: shell.reload);
        final venues = snap.data!;
        if (venues.isEmpty) {
          return RefreshIndicator(
            onRefresh: shell.reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 40),
                EmptyView(
                  icon: Icons.storefront_rounded,
                  title: 'No venue yet',
                  message: 'List your venue first. Once FITKEY verifies it, everything here unlocks.',
                  action: SizedBox(
                    width: 200,
                    child: AppButton(
                      label: 'Start listing',
                      height: 48,
                      onPressed: () async {
                        final s = await venueEditorFor(context, null);
                        if (s != null) await shell.open(s);
                      },
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        final venue =
            venues.where((v) => v.id == _selected).firstOrNull ??
            venues.where((v) => v.status == VenueStatus.live).firstOrNull ??
            venues.first;
        return RefreshIndicator(
          onRefresh: shell.reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              VenueSwitcher(venues: venues, selected: venue.id, onSelected: (id) => setState(() => _selected = id)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.builder(context, venue)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Section heading used inside the Run / Sell / Earn lists.
class TabSection extends StatelessWidget {
  const TabSection(this.title, {super.key, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) =>
      SectionTitle(title, subtitle: subtitle, padding: const EdgeInsets.fromLTRB(0, 22, 0, 12));
}
