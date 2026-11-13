part of '../venue_editor_screen.dart';

// ---------------------------------------------------------------------------
// Step 10 — member-style preview, tap any section to edit, checklist, commission plan, agreement + submit
// ---------------------------------------------------------------------------
class _ReviewStep extends StatelessWidget {
  const _ReviewStep({
    required this.venue,
    required this.schedule,
    required this.pricing,
    required this.problems,
    required this.checklist,
    required this.agreementAccepted,
    required this.onEdit,
  });

  final PartnerVenue venue;
  final WeekSchedule schedule;
  final _PricingState pricing;
  final List<({int step, String message})> problems;
  final VenueChecklist? checklist;
  final bool agreementAccepted;
  final ValueChanged<int> onEdit;

  @override
  Widget build(BuildContext context) {
    final v = venue;
    final visual = venueVisual(v.categories.firstOrNull ?? '');
    final location = [v.address, v.area, v.city].where((s) => s.trim().isNotEmpty).join(', ');
    // Server checklist items that the local checks didn't already flag (e.g. documents rejected by admin).
    final localSteps = problems.map((p) => p.step + 1).toSet();
    final serverOnly = (checklist?.missing ?? const <ChecklistItem>[]).where((m) => !localSteps.contains(m.step) && m.step < 10);
    final todo = [
      for (final p in problems) (step: p.step, text: 'Step ${p.step + 1} · ${p.message}'),
      for (final m in serverOnly) (step: m.step - 1, text: 'Step ${m.step} · ${m.hint ?? m.label}'),
    ];
    final total = _VenueEditorScreenState.titles.length - 1;
    final percent = checklist?.percent ?? (((total - problems.length) / total) * 100).round();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _StepIntro('Review your listing', 'This is how members will see you. Tap any section to change it.'),
        // ---- progress ----
        AppCard(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            SizedBox(
              width: 52,
              height: 52,
              child: Stack(alignment: Alignment.center, children: [
                CircularProgressIndicator(
                  value: percent / 100,
                  strokeWidth: 5,
                  color: todo.isEmpty ? AppColors.green : AppColors.primary,
                  backgroundColor: AppColors.surfaceAlt,
                ),
                Text('$percent%', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              ]),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(todo.isEmpty ? 'Ready to submit' : '${todo.length} thing${todo.length == 1 ? '' : 's'} left',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Text(
                  todo.isEmpty
                      ? 'Accept the partner agreement and submit — we review within 48 hours.'
                      : 'Finish these to submit. You can save a draft any time.',
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35),
                ),
              ]),
            ),
          ]),
        ),
        if (todo.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.amberSoft, borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Still to do', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF9A5B00))),
              const SizedBox(height: 6),
              for (final t in todo) _todo(t.text, () => onEdit(t.step)),
            ]),
          ),
        const SizedBox(height: 16),
        // ---- member preview ----
        _MemberPreview(venue: v, visual: visual, location: location, onEdit: onEdit),
        const SizedBox(height: 14),
        _section(1, Icons.storefront_rounded, AppColors.blue, 'About',
            v.description.trim().isEmpty ? 'No description' : v.description.trim(),
            extra: [v.contactPhone, v.contactEmail].where((s) => s.trim().isNotEmpty).join(' · ')),
        _section(2, Icons.place_rounded, AppColors.red, 'Location', location.isEmpty ? 'No address' : location,
            extra: v.latitude == null ? 'Map pin not set' : 'Map pin set'),
        _section(3, Icons.schedule_rounded, AppColors.purple, 'Timings', scheduleSummary(schedule), extra: [
          if (schedule.ladies.isNotEmpty)
            'Ladies only: ${schedule.ladies.map((w) => '${prettyRange(w.start, w.end)} (${prettyDays(w.days)})').join('; ')}',
          v.fitkeyPassMode == 'blocked' && v.passBlocks.isNotEmpty
              ? v.passBlocks.map(passBlockLabel).join('\n')
              : 'FitKey pass valid at all open hours',
          if (v.closures.isNotEmpty) '${v.closures.length} closed date${v.closures.length == 1 ? '' : 's'} coming up',
        ].join('\n')),
        _section(5, Icons.checklist_rounded, AppColors.green, 'Facilities', [
          v.trainerAvailable ? 'Trainer available' : 'No trainer',
          if (v.amenities.isNotEmpty) v.amenities.map((a) => amenityLabels[a]?.$1 ?? a).join(', '),
        ].join(' · '),
            extra: v.equipment.isEmpty ? null : v.equipment.join(', ')),
        _section(6, Icons.currency_rupee_rounded, AppColors.pink, 'Plans & FitKey pass',
            pricing.offered.isEmpty
                ? 'No plans yet'
                : pricing.offered
                    .map((d) => '${d.label}: ${d.pricePaise == null ? '—' : formatPaise(d.pricePaise!)}')
                    .join(' · '),
            extra: v.monthlyFeePaise == null
                ? 'Monthly fee not set'
                : '${passPreviewLine(v.monthlyFeePaise!, 1)}${v.passAccepted ? '' : ' · consent not given'}'),
        _section(7, Icons.event_seat_rounded, AppColors.blue, 'Slots & capacity',
            '${v.slotMinutes}-min slots · up to ${v.slotCapacity} per slot'
            '${v.passSlotCap != null ? ' (${v.passSlotCap} on FitKey pass)' : ''}',
            extra: [
              if (v.categories.contains('sports_club')) courtsLine(v.courts, v.sports.firstOrNull, v.slotMinutes),
              v.autoAcceptBookings ? 'Bookings auto-accepted' : 'You accept each booking',
            ].join(' · ')),
        _section(8, Icons.verified_user_rounded, AppColors.teal, 'Documents & bank',
            todo.any((t) => t.step == 8) ? 'Optional · add licence, KYC and bank before your first payout' : 'Licence, KYC and bank added'),
        const SizedBox(height: 4),
        const CommissionPlanCard(showPayoutRule: true),
        if (v.status.canSubmit) ...[
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(agreementAccepted ? Icons.verified_rounded : Icons.gavel_rounded,
                size: 18, color: agreementAccepted ? AppColors.green : AppColors.text2),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                agreementAccepted
                    ? 'Partner agreement accepted. Submit and the FITKEY team reviews your listing within 48 hours.'
                    : 'When you submit, you\'ll accept the FitKey partner agreement with an OTP sent to your phone. '
                        'We review within 48 hours.',
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.4),
              ),
            ),
          ]),
        ],
      ],
    );
  }

  Widget _todo(String text, VoidCallback onTap) => Tap(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            const Icon(Icons.radio_button_unchecked_rounded, size: 16, color: AppColors.amber),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(color: Color(0xFF9A5B00), fontWeight: FontWeight.w600))),
            const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.amber),
          ]),
        ),
      );

  Widget _section(int step, IconData icon, Color color, String title, String body, {String? extra}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AppCard(
          onTap: () => onEdit(step),
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconBubble(icon, color: color, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(body,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.text2, fontSize: 13, height: 1.4)),
                if (extra != null && extra.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(extra,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.text3, fontSize: 12, height: 1.4, fontWeight: FontWeight.w600)),
                ],
              ]),
            ),
            const Text('Edit', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 13)),
          ]),
        ),
      );
}

/// Venue card as the member app shows it: photo carousel, name, area, categories, sports, video badge.
class _MemberPreview extends StatefulWidget {
  const _MemberPreview({required this.venue, required this.visual, required this.location, required this.onEdit});

  final PartnerVenue venue;
  final CatVisual visual;
  final String location;
  final ValueChanged<int> onEdit;

  @override
  State<_MemberPreview> createState() => _MemberPreviewState();
}

class _MemberPreviewState extends State<_MemberPreview> {
  int _photo = 0;

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    final photos = v.photos;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SizedBox(
            height: 200,
            child: Stack(fit: StackFit.expand, children: [
              if (photos.isEmpty)
                GestureDetector(onTap: () => widget.onEdit(4), child: NetImage(null, fallback: widget.visual.image))
              else
                PageView.builder(
                  itemCount: photos.length,
                  onPageChanged: (i) => setState(() => _photo = i),
                  itemBuilder: (_, i) => GestureDetector(
                    onTap: () => widget.onEdit(4),
                    child: NetImage(photos[i], fallback: widget.visual.image),
                  ),
                ),
              const IgnorePointer(child: PhotoScrim(strength: 0.7)),
              if (v.id != null) Positioned(left: 12, top: 12, child: StatusPill(v.status, onPhoto: true)),
              if (v.videoUrl != null)
                Positioned(
                  right: 12,
                  top: 12,
                  child: Tag('VIDEO TOUR', icon: Icons.play_circle_fill_rounded, color: Colors.white, bg: Colors.black.withValues(alpha: 0.5)),
                ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 12,
                child: IgnorePointer(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(v.name.trim().isEmpty ? 'Your venue name' : v.name.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
                    if (widget.location.isNotEmpty)
                      Text(widget.location,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    if (photos.length > 1) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        for (var i = 0; i < photos.length; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.only(right: 4),
                            width: i == _photo ? 16 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: i == _photo ? Colors.white : Colors.white54,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                      ]),
                    ],
                  ]),
                ),
              ),
            ]),
          ),
        ),
        Tap(
          onTap: () => widget.onEdit(0),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final c in v.categories) Tag(venueVisual(c).label, icon: venueVisual(c).icon, color: venueVisual(c).color),
              for (final s in v.sports) Tag(sportLabels[s] ?? s, color: AppColors.green),
              if (v.categories.isEmpty) const Text('No category yet', style: TextStyle(color: AppColors.text3)),
            ]),
          ),
        ),
      ]),
    );
  }
}
