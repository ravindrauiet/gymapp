import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/ui.dart';

Color statusColor(VenueStatus s) => switch (s) {
      VenueStatus.live => AppColors.green,
      VenueStatus.submitted || VenueStatus.underReview => AppColors.blue,
      VenueStatus.rejected => AppColors.red,
      VenueStatus.draft => AppColors.amber,
    };

IconData statusIcon(VenueStatus s) => switch (s) {
      VenueStatus.live => Icons.check_circle_rounded,
      VenueStatus.submitted => Icons.schedule_send_rounded,
      VenueStatus.underReview => Icons.manage_search_rounded,
      VenueStatus.rejected => Icons.error_rounded,
      VenueStatus.draft => Icons.edit_note_rounded,
    };

/// Small status label. [onPhoto] gives it a solid white backing so it reads on cover photos.
class StatusPill extends StatelessWidget {
  const StatusPill(this.status, {super.key, this.onPhoto = false});

  final VenueStatus status;
  final bool onPhoto;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
      decoration: BoxDecoration(
        color: onPhoto ? Colors.white : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        boxShadow: onPhoto ? AppShadows.soft : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(status.label.toUpperCase(),
            style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.4, height: 1.1)),
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

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBubble(statusIcon(status), color: statusColor(status), size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Listing status', style: TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
              Text(status.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          for (var i = 0; i < 3; i++) ...[
            _dot(done: step > i, current: step == i + 1),
            if (i < 2)
              Expanded(
                child: Container(
                  height: 3,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: step > i + 1 ? AppColors.green : AppColors.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
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
                      fontWeight: step >= i + 1 ? FontWeight.w800 : FontWeight.w500,
                      color: step >= i + 1 ? AppColors.text : AppColors.text3)),
          ],
        ),
        const SizedBox(height: 14),
        Text(_message(), style: const TextStyle(color: AppColors.text2, height: 1.45, fontSize: 13.5)),
        if (status == VenueStatus.rejected && reviewNote != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.redSoft, borderRadius: BorderRadius.circular(14)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.support_agent_rounded, color: AppColors.red, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text('FITKEY team: $reviewNote',
                    style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w600, height: 1.4)),
              ),
            ]),
          ),
        ],
      ]),
    );
  }

  String _message() => switch (status) {
        VenueStatus.draft => 'Finish your listing and submit it — our team verifies every venue before it goes live.',
        VenueStatus.submitted => 'Thanks! Your listing is in the queue. We usually review within 2 working days.',
        VenueStatus.underReview => 'Our team is verifying your details. We may call you to confirm.',
        VenueStatus.live => 'Your venue is live — FITKEY members can find you and check in.',
        VenueStatus.rejected => 'A few changes are needed. Update your listing and submit again.',
      };

  Widget _dot({required bool done, required bool current}) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done ? AppColors.green : (current ? AppColors.greenSoft : AppColors.surfaceAlt),
          border: Border.all(color: done || current ? AppColors.green : AppColors.line, width: 2),
        ),
        child: done ? const Icon(Icons.check_rounded, size: 14, color: Colors.white) : null,
      );
}
