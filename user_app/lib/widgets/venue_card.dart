import 'package:fitkey_core/fitkey_core.dart' show formatTimeOfDay;
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/ui.dart';

/// Whether a venue is open right now, from its "HH:MM:SS" opening hours.
bool? isOpenNow(String? opensAt, String? closesAt, [DateTime? at]) {
  int? mins(String? t) =>
      t == null || t.length < 5 ? null : int.parse(t.substring(0, 2)) * 60 + int.parse(t.substring(3, 5));
  final o = mins(opensAt), c = mins(closesAt);
  if (o == null || c == null) return null;
  final now = at ?? DateTime.now();
  final n = now.hour * 60 + now.minute;
  return c > o ? (n >= o && n < c) : (n >= o || n < c); // c <= o: closes after midnight
}

/// Full-width venue card with a large photo, in the style of restaurant listings.
class VenueCard extends StatelessWidget {
  const VenueCard({super.key, required this.venue, required this.onTap, this.compact = false});

  final VenueSummary venue;
  final VoidCallback onTap;

  /// Narrower card for horizontal carousels.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cat = venueVisual(venue.categories.isEmpty ? '' : venue.categories.first);
    final open = isOpenNow(venue.opensAt, venue.closesAt);
    final labels = venue.categories.map((c) => venueVisual(c).label).join(' • ');

    return Tap(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(22), boxShadow: AppShadows.card),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: compact ? 130 : 190,
            child: Stack(fit: StackFit.expand, children: [
              NetImage(venue.coverPhoto, fallback: cat.image),
              const PhotoScrim(strength: 0.55),
              Positioned(
                left: 12,
                top: 12,
                child: Row(children: [
                  if (open != null)
                    Tag(open ? 'OPEN NOW' : 'CLOSED', color: open ? AppColors.green : AppColors.text2, solid: true, dense: true),
                  if (venue.trainerAvailable) ...[
                    const SizedBox(width: 6),
                    const Tag('TRAINER', color: AppColors.ink, bg: Colors.white, icon: Icons.sports_rounded, dense: true),
                  ],
                ]),
              ),
              if (venue.distanceKm != null)
                Positioned(
                  right: 12,
                  top: 12,
                  child: Tag('${venue.distanceKm!.toStringAsFixed(1)} km',
                      color: AppColors.ink, bg: Colors.white, icon: Icons.near_me_rounded, dense: true),
                ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 12,
                child: Row(children: [
                  Icon(cat.icon, color: Colors.white, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(labels,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5)),
                  ),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, compact ? 12 : 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(venue.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: compact ? 15.5 : 17, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.location_on_rounded, size: 15, color: AppColors.text3),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(venue.location,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.text2, fontSize: 13, fontWeight: FontWeight.w500)),
                ),
              ]),
              if (!compact && venue.opensAt != null) ...[
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 10),
                Row(children: [
                  const Icon(Icons.schedule_rounded, size: 15, color: AppColors.text3),
                  const SizedBox(width: 5),
                  Text('${formatTimeOfDay(venue.opensAt)} – ${formatTimeOfDay(venue.closesAt)}',
                      style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (venue.amenities.isNotEmpty)
                    Text('${venue.amenities.length} amenities',
                        style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
                ]),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
