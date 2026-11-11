import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/brd_api.dart';
import '../data/models.dart';
import '../state/partner_session.dart';
import '../ui/ui.dart';
import 'status.dart';

/// Status timeline after submit (BRD §6.4): Submitted → Under review → Changes needed (exact fixes) → Live,
/// with the target review time. [onFix] opens the listing step to fix (step number from the fix).
class ListingStatusTimeline extends StatefulWidget {
  const ListingStatusTimeline({
    super.key,
    required this.entityType,
    required this.entityId,
    required this.status,
    this.onFix,
    this.onAccept,
  });

  final String entityType;
  final String entityId;
  final VenueStatus status;

  /// Jump to a listing step (1-based) to fix it.
  final ValueChanged<int>? onFix;

  /// Shown when status is `approved` (owner must accept the agreement by OTP).
  final VoidCallback? onAccept;

  @override
  State<ListingStatusTimeline> createState() => _ListingStatusTimelineState();
}

class _ListingStatusTimelineState extends State<ListingStatusTimeline> {
  ListingTimeline? _t;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ListingStatusTimeline old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status || old.entityId != widget.entityId) _load();
  }

  Future<void> _load() async {
    try {
      final t = await context.read<PartnerSession>().api.listingTimeline(widget.entityType, widget.entityId);
      if (mounted) setState(() => _t = t);
    } catch (_) {}
  }

  static const _stages = [
    (VenueStatus.submitted, 'Submitted'),
    (VenueStatus.underReview, 'Under review'),
    (VenueStatus.changesNeeded, 'Changes needed'),
    (VenueStatus.live, 'Live'),
  ];

  int get _stageIndex => switch (widget.status) {
        VenueStatus.draft || VenueStatus.rejected => -1,
        VenueStatus.submitted => 0,
        VenueStatus.underReview => 1,
        VenueStatus.changesNeeded => 2,
        VenueStatus.approved => 2,
        VenueStatus.live => 3,
      };

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM, h:mm a');
    final idx = _stageIndex;
    final fixes = _t?.openFixes ?? const <ListingFix>[];
    final target = _t?.reviewTargetHours ?? 48;
    final events = _t?.events ?? const <TimelineEvent>[];
    DateTime? when(VenueStatus s) => events.where((e) => e.status == s).lastOrNull?.at;

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBubble(statusIcon(widget.status), color: statusColor(widget.status), size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Listing status', style: TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
              Text(widget.status.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ]),
          ),
          StatusPill(widget.status),
        ]),
        const SizedBox(height: 14),
        for (var i = 0; i < _stages.length; i++)
          // "Changes needed" only appears when it actually happened.
          if (i != 2 || widget.status == VenueStatus.changesNeeded || when(VenueStatus.changesNeeded) != null)
            _row(
              label: _stages[i].$2,
              done: idx > i || (idx == 3 && i == 3),
              current: idx == i,
              warn: i == 2,
              time: when(_stages[i].$1),
              fmt: fmt,
              last: i == _stages.length - 1,
            ),
        const SizedBox(height: 6),
        Text(
          switch (widget.status) {
            VenueStatus.submitted || VenueStatus.underReview => 'We review new listings within $target hours.',
            VenueStatus.changesNeeded => 'Fix the items below, then submit again.',
            VenueStatus.approved => 'Approved! Accept the FitKey partner agreement by OTP to go live.',
            VenueStatus.live => 'You are live — FitKey members can find and book you.',
            VenueStatus.rejected => 'Not approved. Contact FITKEY support for details.',
            VenueStatus.draft => 'Finish all steps and submit — we review within $target hours.',
          },
          style: const TextStyle(color: AppColors.text2, fontSize: 13, height: 1.4),
        ),
        if (fixes.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final f in fixes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                shadow: false,
                color: AppColors.amberSoft,
                padding: const EdgeInsets.all(12),
                onTap: widget.onFix == null || f.step <= 0 ? null : () => widget.onFix!(f.step),
                child: Row(children: [
                  const Icon(Icons.build_circle_rounded, color: AppColors.amber, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      f.step > 0 ? 'Step ${f.step}: ${f.message}' : f.message,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                  if (widget.onFix != null && f.step > 0)
                    const Text('Fix', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800)),
                ]),
              ),
            ),
        ],
        if (widget.status == VenueStatus.approved && widget.onAccept != null) ...[
          const SizedBox(height: 10),
          AppButton(label: 'Review & accept agreement', icon: Icons.verified_user_rounded, onPressed: widget.onAccept),
        ],
      ]),
    );
  }

  Widget _row({
    required String label,
    required bool done,
    required bool current,
    required bool warn,
    required DateTime? time,
    required DateFormat fmt,
    required bool last,
  }) {
    final color = warn && current ? AppColors.amber : (done || current ? AppColors.green : AppColors.line);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? AppColors.green : (current ? color.withValues(alpha: 0.15) : AppColors.surfaceAlt),
              border: Border.all(color: color, width: 2),
            ),
            child: done ? const Icon(Icons.check_rounded, size: 12, color: Colors.white) : null,
          ),
          if (!last) Expanded(child: Container(width: 2, color: done ? AppColors.green : AppColors.line)),
        ]),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(
                      fontWeight: done || current ? FontWeight.w800 : FontWeight.w500,
                      color: done || current ? AppColors.text : AppColors.text3,
                    )),
              ),
              if (time != null)
                Text(fmt.format(time), style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ]),
    );
  }
}
