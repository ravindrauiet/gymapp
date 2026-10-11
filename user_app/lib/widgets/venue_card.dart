import 'package:flutter/material.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../data/models.dart';

class VenueCard extends StatelessWidget {
  const VenueCard({super.key, required this.venue, required this.onTap, this.compact = false});

  final VenueSummary venue;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final firstCategory = venue.categories.isEmpty ? null : venue.categories.first;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(children: [
              VenueImage(url: venue.coverPhoto, category: firstCategory, height: compact ? 120 : 160),
              if (venue.distanceKm != null)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                    child: Text('${venue.distanceKm!.toStringAsFixed(1)} km',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(venue.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.place_outlined, size: 14, color: FkColors.textSecondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(venue.location,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
                  ),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: venue.categories
                          .take(compact ? 1 : 3)
                          .map((c) => CategoryPill(venueCategory(c), dense: true))
                          .toList(),
                    ),
                  ),
                  if (!compact && venue.opensAt != null)
                    Text('${formatTimeOfDay(venue.opensAt)} – ${formatTimeOfDay(venue.closesAt)}',
                        style: const TextStyle(fontSize: 12, color: FkColors.textSecondary)),
                ]),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
