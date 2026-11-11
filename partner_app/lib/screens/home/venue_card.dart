import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../ui/ui.dart';
import '../../widgets/status.dart';

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: SizedBox(
              height: 150,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NetImage(venue.coverPhoto, fallback: visual.image),
                  const PhotoScrim(strength: 0.55),
                  Positioned(left: 12, top: 12, child: StatusPill(venue.status, onPhoto: true)),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 12,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final c in venue.categories.take(3))
                          Tag(
                            venueVisual(c).label,
                            icon: venueVisual(c).icon,
                            color: Colors.white,
                            bg: Colors.black.withValues(alpha: 0.35),
                            dense: true,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        venue.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: -0.2),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(Icons.place_rounded, size: 14, color: AppColors.text3),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              venue.location.isEmpty ? 'Location not added' : venue.location,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.text2,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (live)
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            Tag('${venue.todayCheckins} today', icon: Icons.login_rounded, color: AppColors.green),
                            Tag(
                              '${venue.monthCheckins} this month',
                              icon: Icons.calendar_month_rounded,
                              color: AppColors.blue,
                            ),
                            if (venue.ratingAvg != null && venue.ratingCount > 0)
                              Tag('${venue.ratingAvg!.toStringAsFixed(1)} ★', color: AppColors.amber),
                          ],
                        )
                      else if (venue.status == VenueStatus.rejected && venue.reviewNote != null)
                        Text(
                          venue.reviewNote!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.red, fontSize: 12.5, fontWeight: FontWeight.w600),
                        )
                      else
                        Text(
                          venue.status == VenueStatus.draft
                              ? 'Finish your listing and submit for review'
                              : 'FITKEY is reviewing your listing',
                          style: const TextStyle(color: AppColors.text3, fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                    ],
                  ),
                ),
                if (onShowQr != null)
                  Tap(
                    onTap: onShowQr,
                    child: Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(14)),
                      child: const Column(
                        children: [
                          Icon(Icons.qr_code_2_rounded, color: Colors.white, size: 22),
                          SizedBox(height: 2),
                          Text(
                            'QR',
                            style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
