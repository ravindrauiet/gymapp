import 'package:fitkey_core/fitkey_core.dart' show formatPaise, formatDayDate, apiDate;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'trainers_screen.dart' show TrainerMode, sessionStart;

typedef _TrainerData = ({Trainer trainer, List<String> availableSlots});

/// Trainer profile + booking: mode, date (next 7 days) and time slot, then 1-tap booking.
/// Pops with `true` when a session was booked.
class TrainerDetailScreen extends StatefulWidget {
  const TrainerDetailScreen({super.key, required this.trainerId});

  final String trainerId;

  @override
  State<TrainerDetailScreen> createState() => _TrainerDetailScreenState();
}

class _TrainerDetailScreenState extends State<TrainerDetailScreen> {
  late Future<_TrainerData> _future;

  String? _mode;
  late DateTime _date;
  String? _slot;
  bool _booking = false;

  static const _headerHeight = 340.0;
  final _scroll = ScrollController();
  bool _collapsed = false;

  static DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  List<DateTime> get _days => List.generate(7, (i) => _today.add(Duration(days: i)));

  @override
  void initState() {
    super.initState();
    _date = _today;
    _future = _load();
    _scroll.addListener(() {
      final c = _scroll.hasClients && _scroll.offset > _headerHeight - kToolbarHeight - 60;
      if (c != _collapsed) setState(() => _collapsed = c);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<_TrainerData> _load() async {
    final data = await context.read<Session>().api.trainer(widget.trainerId);
    // Start on the first day that still has a bookable slot.
    if (!_days.any((d) => d == _date && _slotsFor(d, data.availableSlots).isNotEmpty)) {
      _date = _days.firstWhere((d) => _slotsFor(d, data.availableSlots).isNotEmpty, orElse: () => _today);
    }
    return data;
  }

  void _retry() => setState(() => _future = _load());

  List<String> _modesOf(Trainer t) =>
      t.trainingModes.isNotEmpty ? t.trainingModes : TrainerMode.all.map((m) => m.id).toList();

  /// Slots that are still in the future for [day] (and at least 30 minutes away).
  List<String> _slotsFor(DateTime day, List<String> slots) {
    final cutoff = DateTime.now().add(const Duration(minutes: 30));
    return slots.where((s) {
      final start = sessionStart(apiDate(day), s);
      return start == null || start.isAfter(cutoff);
    }).toList();
  }

  Future<void> _book(Trainer trainer) async {
    final mode = _mode, slot = _slot;
    if (mode == null || slot == null) {
      toast(context, 'Pick a time slot for your session', error: true);
      return;
    }
    setState(() => _booking = true);
    try {
      final booking = await context.read<Session>().api.bookTrainer(
        trainerId: trainer.id,
        mode: mode,
        sessionDate: apiDate(_date),
        slotTime: slot,
      );
      if (!mounted) return;
      setState(() => _booking = false);
      await showAppSheet<void>(
        context,
        builder: (ctx) => _SuccessSheet(trainer: trainer, booking: booking),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _booking = false);
      toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_TrainerData>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Scaffold(appBar: AppBar(), body: const _DetailSkeleton());
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Trainer')),
            body: ErrorView(error: snap.error!, onRetry: _retry),
          );
        }
        final t = snap.data!.trainer;
        final modes = _modesOf(t);
        if (_mode == null || !modes.contains(_mode)) _mode = modes.first;
        final slots = _slotsFor(_date, snap.data!.availableSlots);
        if (_slot != null && !slots.contains(_slot)) _slot = null;

        return Scaffold(
          backgroundColor: AppColors.bg,
          body: CustomScrollView(
            controller: _scroll,
            slivers: [
              _Header(trainer: t, height: _headerHeight, collapsed: _collapsed),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                sliver: SliverList.list(
                  children: [
                    _StatsRow(trainer: t),
                    if (t.bio.trim().isNotEmpty) ...[
                      const SectionTitle('About', padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
                      Text(t.bio, style: const TextStyle(color: AppColors.text2, height: 1.55, fontSize: 14.5)),
                    ],
                    if (t.specializations.isNotEmpty) ...[
                      const SectionTitle('Specializations', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final s in t.specializations) Tag(s, color: AppColors.primary, icon: Icons.bolt_rounded),
                        ],
                      ),
                    ],
                    if (t.certifications.isNotEmpty) ...[
                      const SectionTitle('Certifications', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                      AppCard(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        child: Column(
                          children: [
                            for (var i = 0; i < t.certifications.length; i++) ...[
                              if (i > 0) const Divider(height: 1),
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                child: Row(
                                  children: [
                                    const IconBubble(Icons.workspace_premium_rounded, color: AppColors.green, size: 34),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        t.certifications[i],
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13.5,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                    const SectionTitle('Session type', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
                    Row(
                      children: [
                        for (var i = 0; i < modes.length; i++) ...[
                          if (i > 0) const SizedBox(width: 10),
                          Expanded(
                            child: _ModeCard(
                              mode: TrainerMode.of(modes[i]),
                              selected: _mode == modes[i],
                              onTap: () => setState(() => _mode = modes[i]),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SectionTitle('Pick a date', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
                    _DateStrip(
                      days: _days,
                      selected: _date,
                      isAvailable: (d) => _slotsFor(d, snap.data!.availableSlots).isNotEmpty,
                      onSelected: (d) => setState(() {
                        _date = d;
                        _slot = null;
                      }),
                    ),
                    SectionTitle(
                      'Pick a time',
                      subtitle: '60-minute session on ${formatDayDate(_date)}',
                      padding: const EdgeInsets.fromLTRB(0, 28, 0, 12),
                    ),
                    if (slots.isEmpty)
                      AppCard(
                        child: Row(
                          children: [
                            const IconBubble(Icons.event_busy_rounded, color: AppColors.amber, size: 38),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'No slots left for this day. Please pick another date.',
                                style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      _SlotGrid(slots: slots, selected: _slot, onSelected: (s) => setState(() => _slot = s)),
                    const SectionTitle('Price summary', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
                    _PriceSummary(trainer: t, mode: TrainerMode.of(_mode!), date: _date, slot: _slot),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: BottomActionBar(
            leading: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatPaise(t.hourlyRatePaise),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                ),
                Text(
                  _slot == null ? 'Select a slot' : '${DateFormat('d MMM').format(_date)} · $_slot',
                  style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            child: AppButton(
              label: _slot == null ? 'Select a time slot' : 'Book session · ${formatPaise(t.hourlyRatePaise)}',
              busy: _booking,
              onPressed: _slot == null ? null : () => _book(t),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.trainer, required this.height, required this.collapsed});
  final Trainer trainer;
  final double height;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final t = trainer;
    return SliverAppBar(
      pinned: true,
      expandedHeight: height,
      backgroundColor: AppColors.surface,
      leading: Padding(
        padding: const EdgeInsets.all(8),
        child: Tap(
          onTap: () => Navigator.of(context).maybePop(),
          child: Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
              boxShadow: AppShadows.soft,
            ),
            child: const Icon(Icons.arrow_back_rounded, color: AppColors.text, size: 22),
          ),
        ),
      ),
      title: AnimatedOpacity(
        opacity: collapsed ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Text(t.name),
      ),
      flexibleSpace: Builder(
        builder: (context) {
          return FlexibleSpaceBar(
            collapseMode: CollapseMode.parallax,
            background: Stack(
              fit: StackFit.expand,
              children: [
                NetImage(t.photoUrl, fallback: AppImages.homeWorkout),
                const PhotoScrim(strength: 0.8),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 18,
                  child: AnimatedOpacity(
                    opacity: collapsed ? 0 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Tag(
                          'VERIFIED TRAINER',
                          color: AppColors.ink,
                          bg: Colors.white,
                          icon: Icons.verified_rounded,
                          dense: true,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          t.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.6,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (t.specializations.isNotEmpty)
                          Text(
                            t.specializations.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.trainer});
  final Trainer trainer;

  @override
  Widget build(BuildContext context) {
    Widget cell(IconData icon, Color color, String value, String label) => Expanded(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 4),
              Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
    Widget sep() => Container(width: 1, height: 30, color: AppColors.line);

    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          cell(Icons.star_rounded, AppColors.amber, trainer.rating.toStringAsFixed(1), 'Rating'),
          sep(),
          cell(Icons.reviews_rounded, AppColors.blue, '${trainer.reviewCount}', 'Reviews'),
          sep(),
          cell(Icons.timer_rounded, AppColors.primary, '60', 'Min / session'),
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.mode, required this.selected, required this.onTap});
  final TrainerMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
        decoration: BoxDecoration(
          color: selected ? mode.color.withValues(alpha: 0.08) : AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? mode.color : AppColors.line, width: selected ? 1.6 : 1),
          boxShadow: selected ? null : AppShadows.soft,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconBubble(mode.icon, color: mode.color, size: 34),
                const Spacer(),
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  size: 18,
                  color: selected ? mode.color : AppColors.text3,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(mode.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            const SizedBox(height: 2),
            Text(
              mode.long,
              maxLines: 2,
              style: const TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w500, height: 1.3),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateStrip extends StatelessWidget {
  const _DateStrip({required this.days, required this.selected, required this.isAvailable, required this.onSelected});
  final List<DateTime> days;
  final DateTime selected;
  final bool Function(DateTime) isAvailable;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 82,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: days.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final d = days[i];
          final on = d == selected;
          final ok = isAvailable(d);
          final top = i == 0 ? 'Today' : (i == 1 ? 'Tmrw' : DateFormat('EEE').format(d));
          return Tap(
            onTap: ok ? () => onSelected(d) : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 64,
              decoration: BoxDecoration(
                color: on ? AppColors.ink : (ok ? AppColors.surface : AppColors.surfaceAlt),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: on ? AppColors.ink : AppColors.line),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    top,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: on ? Colors.white.withValues(alpha: 0.75) : AppColors.text2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${d.day}',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: on ? Colors.white : (ok ? AppColors.text : AppColors.text3),
                    ),
                  ),
                  Text(
                    DateFormat('MMM').format(d),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: on ? Colors.white.withValues(alpha: 0.75) : AppColors.text3,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SlotGrid extends StatelessWidget {
  const _SlotGrid({required this.slots, required this.selected, required this.onSelected});
  final List<String> slots;
  final String? selected;
  final ValueChanged<String> onSelected;

  IconData _iconFor(String s) {
    final h = sessionStart('2000-01-01', s)?.hour ?? 12;
    if (h < 12) return Icons.wb_twilight_rounded;
    if (h < 17) return Icons.wb_sunny_rounded;
    return Icons.nights_stay_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: slots.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: 48,
      ),
      itemBuilder: (_, i) {
        final s = slots[i];
        final on = s == selected;
        return Tap(
          onTap: () => onSelected(s),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? AppColors.primarySoft : AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: on ? AppColors.primary : AppColors.line, width: on ? 1.6 : 1),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(_iconFor(s), size: 14, color: on ? AppColors.primary : AppColors.text3),
                const SizedBox(width: 5),
                Text(
                  s,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: on ? AppColors.primary : AppColors.text,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PriceSummary extends StatelessWidget {
  const _PriceSummary({required this.trainer, required this.mode, required this.date, required this.slot});
  final Trainer trainer;
  final TrainerMode mode;
  final DateTime date;
  final String? slot;

  @override
  Widget build(BuildContext context) {
    Widget row(String k, String v, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              k,
              style: TextStyle(
                color: bold ? AppColors.text : AppColors.text2,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                fontSize: bold ? 15.5 : 14,
              ),
            ),
          ),
          Text(
            v,
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: bold ? 16.5 : 14),
          ),
        ],
      ),
    );
    return AppCard(
      child: Column(
        children: [
          row('Session type', mode.label),
          row('When', slot == null ? formatDayDate(date) : '${formatDayDate(date)}, $slot'),
          row('Duration', '60 min'),
          row('Session fee', formatPaise(trainer.hourlyRatePaise)),
          const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1)),
          row('Total', formatPaise(trainer.hourlyRatePaise), bold: true),
        ],
      ),
    );
  }
}

class _SuccessSheet extends StatelessWidget {
  const _SuccessSheet({required this.trainer, required this.booking});
  final Trainer trainer;
  final TrainerBooking booking;

  @override
  Widget build(BuildContext context) {
    final mode = TrainerMode.of(booking.mode);
    final date = DateTime.tryParse(booking.sessionDate);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppColors.greenSoft,
                shape: BoxShape.circle,
                boxShadow: AppShadows.glow(AppColors.green),
              ),
              child: const Icon(Icons.check_rounded, color: AppColors.green, size: 48),
            ),
            const SizedBox(height: 16),
            const Text(
              'Session booked!',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4),
            ),
            const SizedBox(height: 6),
            Text(
              '${trainer.name} will see you ${mode.label.toLowerCase()}.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 18),
            AppCard(
              shadow: false,
              border: true,
              child: Row(
                children: [
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: NetImage(trainer.photoUrl, fallback: AppImages.homeWorkout, radius: 14),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          date == null ? booking.sessionDate : formatDayDate(date),
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${booking.slotTime} · ${mode.label} · 60 min',
                          style: const TextStyle(color: AppColors.text2, fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    formatPaise(booking.amountPaise),
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            AppButton(label: 'View my bookings', onPressed: () => Navigator.of(context).pop()),
          ],
        ),
      ),
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: SingleChildScrollView(
        physics: NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(height: 280, radius: 0),
            Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(height: 64, radius: 20),
                  SizedBox(height: 24),
                  SkeletonBox(height: 18, width: 120),
                  SizedBox(height: 12),
                  SkeletonBox(height: 12),
                  SizedBox(height: 8),
                  SkeletonBox(height: 12),
                  SizedBox(height: 8),
                  SkeletonBox(height: 12, width: 200),
                  SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(child: SkeletonBox(height: 100, radius: 18)),
                      SizedBox(width: 10),
                      Expanded(child: SkeletonBox(height: 100, radius: 18)),
                      SizedBox(width: 10),
                      Expanded(child: SkeletonBox(height: 100, radius: 18)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
