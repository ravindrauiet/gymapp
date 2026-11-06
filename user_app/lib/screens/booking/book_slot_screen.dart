import 'package:fitkey_core/fitkey_core.dart' show formatDayDate, formatTimeOfDay;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/booking_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../plans/plans_screen.dart';
import 'my_bookings_screen.dart';

/// Centre page → pick a day → pick an hourly slot → see the cost → confirm.
class BookSlotScreen extends StatefulWidget {
  const BookSlotScreen({super.key, required this.venueId, required this.venueName});

  final String venueId;
  final String venueName;

  @override
  State<BookSlotScreen> createState() => _BookSlotScreenState();
}

class _BookSlotScreenState extends State<BookSlotScreen> {
  String? _date;
  String? _start;
  bool _busy = false;
  late Future<SlotsInfo> _future = _load();

  Future<SlotsInfo> _load() => context.read<Session>().api.venueSlots(widget.venueId, date: _date);

  void _reload() => setState(() {
        _start = null;
        _future = _load();
      });

  void _pickDay(String date) {
    if (date == _date) return;
    _date = date;
    _reload();
  }

  Future<void> _confirm(SlotsInfo info, Slot slot) async {
    final ok = await showAppSheet<bool>(
      context,
      builder: (ctx) => _ConfirmSheet(info: info, slot: slot, venueName: widget.venueName),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final b = await context.read<Session>().api.bookSlot(venueId: widget.venueId, date: info.date, start: slot.start);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      toast(context, 'Booked ${formatTimeOfDay(b.slotStart)} on ${formatDayDate(parseDay(b.slotDate))} · ${b.costLabel ?? ''}',
          icon: Icons.event_available_rounded);
      await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MyBookingsScreen()));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toast(context, friendlyError(e), error: true);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Book a slot'),
          Text(widget.venueName,
              style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
        ]),
      ),
      body: FutureBuilder<SlotsInfo>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Shimmer(
              child: ListView(padding: const EdgeInsets.all(16), physics: const NeverScrollableScrollPhysics(), children: [
                const SkeletonBox(height: 64, radius: 16),
                const SizedBox(height: 16),
                const SkeletonBox(height: 84, radius: 18),
                const SizedBox(height: 20),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  for (var i = 0; i < 9; i++) const SkeletonBox(height: 62, width: 100, radius: 14),
                ]),
              ]),
            );
          }
          if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
          final info = snap.data!;
          _date ??= info.date;
          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _future.catchError((_) => info);
            },
            child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              const SizedBox(height: 12),
              _DayStrip(days: info.days, selected: info.date, onPick: _pickDay),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _CostCard(cost: info.cost, venueName: widget.venueName),
              ),
              if (info.myBooking != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: AppCard(
                    color: AppColors.greenSoft,
                    shadow: false,
                    onTap: () => push(context, const MyBookingsScreen()),
                    child: Row(children: [
                      const Icon(Icons.event_available_rounded, color: AppColors.green),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "You're booked ${formatTimeOfDay(info.myBooking!['slotStart'])} – "
                          '${formatTimeOfDay(info.myBooking!['slotEnd'])} this day. One booking per centre per day.',
                          style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF0E6B49), height: 1.35),
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.green),
                    ]),
                  ),
                ),
              SectionTitle('Time slots',
                  subtitle: info.slots.isEmpty ? null : '1 hour each · ${info.slots.first.capacity} people per slot',
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 12)),
              if (info.slots.isEmpty)
                const EmptyView(
                  icon: Icons.event_busy_rounded,
                  title: 'Closed this day',
                  message: 'This centre is not open on the selected day. Pick another day above.',
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: LayoutBuilder(builder: (context, c) {
                    final w = (c.maxWidth - 20) / 3;
                    return Wrap(spacing: 10, runSpacing: 10, children: [
                      for (final s in info.slots)
                        SizedBox(
                          width: w,
                          child: _SlotTile(
                            slot: s,
                            selected: s.start == _start,
                            enabled: s.available && info.myBooking == null,
                            onTap: () => setState(() => _start = s.start),
                          ),
                        ),
                    ]);
                  }),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                child: Row(children: [
                  const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.text3),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Free cancellation until ${info.freeCancelHours} h before your slot. Scan the centre QR when you arrive.',
                      style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                    ),
                  ),
                ]),
              ),
            ]),
          );
        },
      ),
      bottomNavigationBar: FutureBuilder<SlotsInfo>(
        future: _future,
        builder: (context, snap) {
          final info = snap.data;
          if (info == null || snap.connectionState != ConnectionState.done) return const SizedBox.shrink();
          final slot = info.slots.where((s) => s.start == _start).firstOrNull;
          return BottomActionBar(
            leading: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('This visit', style: TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(info.cost.canPay ? info.cost.label : 'Not covered',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ),
            ]),
            child: info.cost.canPay
                ? AppButton(
                    label: slot == null ? 'Pick a slot' : 'Book ${formatTimeOfDay(slot.start)}',
                    icon: Icons.event_available_rounded,
                    busy: _busy,
                    onPressed: slot == null ? null : () => _confirm(info, slot),
                  )
                : AppButton(
                    label: 'Get FitKey pass',
                    icon: Icons.key_rounded,
                    color: AppColors.ink,
                    onPressed: () => push(context, const PlansScreen()),
                  ),
          );
        },
      ),
    );
  }
}

class _DayStrip extends StatelessWidget {
  const _DayStrip({required this.days, required this.selected, required this.onPick});
  final List<SlotDay> days;
  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    const wd = {'mon': 'Mon', 'tue': 'Tue', 'wed': 'Wed', 'thu': 'Thu', 'fri': 'Fri', 'sat': 'Sat', 'sun': 'Sun'};
    return SizedBox(
      height: 76,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: days.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final d = days[i];
          final on = d.date == selected;
          final day = parseDay(d.date);
          return Tap(
            onTap: () => onPick(d.date),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 58,
              decoration: BoxDecoration(
                color: on ? AppColors.ink : AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: on ? AppColors.ink : AppColors.line),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(i == 0 ? 'Today' : wd[d.weekday] ?? d.weekday,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: on ? Colors.white70 : (d.open ? AppColors.text2 : AppColors.text3))),
                const SizedBox(height: 4),
                Text('${day.day}',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: on ? Colors.white : (d.open ? AppColors.text : AppColors.text3),
                      decoration: d.open ? null : TextDecoration.lineThrough,
                    )),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _CostCard extends StatelessWidget {
  const _CostCard({required this.cost, required this.venueName});
  final VisitCost cost;
  final String venueName;

  @override
  Widget build(BuildContext context) {
    final (icon, color, title, sub) = switch (cost.method) {
      'membership' => (Icons.card_membership_rounded, AppColors.green, 'Included in your membership',
          cost.membershipName == null ? 'Free with your $venueName membership' : 'Free with ${cost.membershipName}'),
      'legacy_pass' => (Icons.verified_rounded, AppColors.green, 'Included in your pass', 'Your FitKey pass covers this centre'),
      'session' => (Icons.confirmation_number_rounded, AppColors.blue, cost.label,
          cost.sufficient ? 'From your FitKey session plan' : 'No sessions left on your plan'),
      'coins' => (Icons.toll_rounded, AppColors.amber, cost.label,
          cost.balance == null ? 'Paid with FitKey coins' : 'Balance: ${cost.balance} coins${cost.sufficient ? '' : ' — not enough'}'),
      _ => (Icons.lock_rounded, AppColors.red, 'Not covered yet',
          cost.available ? 'Get a FitKey pass or a $venueName membership to book' : cost.label),
    };
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBubble(icon, color: color, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('COST OF THIS VISIT',
                  style: TextStyle(fontSize: 10.5, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: AppColors.text3)),
              const SizedBox(height: 2),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16.5)),
              Text(sub, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
            ]),
          ),
        ]),
        if (cost.membershipLimit != null) ...[
          const SizedBox(height: 10),
          Text('${cost.membershipLimit} — this visit uses your FitKey pass instead.',
              style: const TextStyle(color: AppColors.amber, fontWeight: FontWeight.w700, fontSize: 12.5)),
        ],
      ]),
    );
  }
}

class _SlotTile extends StatelessWidget {
  const _SlotTile({required this.slot, required this.selected, required this.enabled, required this.onTap});
  final Slot slot;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = slot.past
        ? 'Started'
        : slot.left == 0
            ? 'Full'
            : slot.left <= 5
                ? 'Only ${slot.left} left'
                : '${slot.left} left';
    final fg = selected ? Colors.white : (enabled ? AppColors.text : AppColors.text3);
    return Tap(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : (enabled ? AppColors.surface : AppColors.surfaceAlt),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? AppColors.primary : AppColors.line),
          boxShadow: selected ? AppShadows.glow(AppColors.primary) : null,
        ),
        child: Column(children: [
          Text(formatTimeOfDay(slot.start), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, color: fg)),
          const SizedBox(height: 2),
          Text(sub,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: selected
                    ? Colors.white70
                    : !enabled
                        ? AppColors.text3
                        : slot.left <= 5
                            ? AppColors.red
                            : AppColors.green,
              )),
        ]),
      ),
    );
  }
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.info, required this.slot, required this.venueName});
  final SlotsInfo info;
  final Slot slot;
  final String venueName;

  @override
  Widget build(BuildContext context) {
    final cost = info.cost;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Confirm booking', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          const SizedBox(height: 14),
          AppCard(
            border: true,
            shadow: false,
            child: Column(children: [
              _Line(Icons.storefront_rounded, 'Centre', venueName),
              _Line(Icons.today_rounded, 'Day', formatDayDate(parseDay(info.date))),
              _Line(Icons.schedule_rounded, 'Slot', '${formatTimeOfDay(slot.start)} – ${formatTimeOfDay(slot.end)}'),
              _Line(Icons.payments_rounded, 'You pay', cost.label, strong: true),
            ]),
          ),
          const SizedBox(height: 12),
          Text(
            cost.isFree
                ? 'Nothing is charged. Cancel any time before the slot to free your spot.'
                : 'Charged now from your FitKey pass. Cancel until ${info.freeCancelHours} h before the slot to get it back; '
                    'later cancellations are not refunded.',
            style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 18),
          AppButton(label: 'Confirm · ${cost.label}', icon: Icons.check_rounded, onPressed: () => Navigator.pop(context, true)),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(foregroundColor: AppColors.text2),
            child: const Text('Back'),
          ),
        ]),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.label, this.value, {this.strong = false});
  final IconData icon;
  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 18, color: AppColors.text3),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(value,
              textAlign: TextAlign.right,
              style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.w700, fontSize: strong ? 15.5 : 14)),
        ),
      ]),
    );
  }
}
