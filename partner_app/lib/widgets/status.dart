import 'package:fitkey_core/fitkey_core.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';

Color statusColor(VenueStatus s) => switch (s) {
      VenueStatus.live => FkColors.lime,
      VenueStatus.submitted || VenueStatus.underReview => FkColors.sky,
      VenueStatus.rejected => FkColors.danger,
      VenueStatus.draft => FkColors.textSecondary,
    };

class StatusPill extends StatelessWidget {
  const StatusPill(this.status, {super.key});

  final VenueStatus status;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(status.label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

/// Submitted → Under review → Live progress (BRD P8).
class StatusTimeline extends StatelessWidget {
  const StatusTimeline({super.key, required this.status, this.reviewNote});

  final VenueStatus status;
  final String? reviewNote;

  @override
  Widget build(BuildContext context) {
    final step = switch (status) {
      VenueStatus.draft || VenueStatus.rejected => 0,
      VenueStatus.submitted => 1,
      VenueStatus.underReview => 2,
      VenueStatus.live => 3,
    };
    const labels = ['Submitted', 'Under review', 'Live'];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            for (var i = 0; i < 3; i++) ...[
              _dot(done: step > i, current: step == i + 1),
              if (i < 2)
                Expanded(child: Container(height: 2, color: step > i + 1 ? FkColors.lime : FkColors.outline)),
            ],
          ]),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < 3; i++)
                Text(labels[i],
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: step >= i + 1 ? FontWeight.w700 : FontWeight.w400,
                        color: step >= i + 1 ? FkColors.textPrimary : FkColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 12),
          Text(_message(), style: const TextStyle(color: FkColors.textSecondary, height: 1.4)),
          if (status == VenueStatus.rejected && reviewNote != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: FkColors.danger.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: FkColors.danger.withValues(alpha: 0.4)),
              ),
              child: Text('FITKEY team: $reviewNote', style: const TextStyle(color: FkColors.danger)),
            ),
          ],
        ]),
      ),
    );
  }

  String _message() => switch (status) {
        VenueStatus.draft => 'Finish your listing and submit it — our team verifies every venue before it goes live.',
        VenueStatus.submitted => 'Thanks! Your listing is in the queue. We usually review within 2 working days.',
        VenueStatus.underReview => 'Our team is verifying your details. We may call you to confirm.',
        VenueStatus.live => 'Your venue is live — FITKEY members can find you and check in.',
        VenueStatus.rejected => 'A few changes are needed. Update your listing and submit again.',
      };

  Widget _dot({required bool done, required bool current}) => Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done ? FkColors.lime : FkColors.surfaceHigh,
          border: Border.all(color: current || done ? FkColors.lime : FkColors.outline, width: 2),
        ),
        child: done ? const Icon(Icons.check, size: 14, color: Colors.black) : null,
      );
}
