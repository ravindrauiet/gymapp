import 'package:fitkey_core/fitkey_core.dart' show apiDate, formatClock, formatDayDate, formatPaise, formatTimeOfDay;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../../data/memberships_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import 'paid_via.dart';

/// Slot bookings, occupancy and check-ins for one venue, day by day.
class PartnerBookingsScreen extends StatefulWidget {
  const PartnerBookingsScreen({super.key, required this.venueId, required this.venueName, this.initialTab = 0});

  final String venueId;
  final String venueName;

  /// 0 = bookings & slots, 1 = visits.
  final int initialTab;

  @override
  State<PartnerBookingsScreen> createState() => _PartnerBookingsScreenState();
}

class _PartnerBookingsScreenState extends State<PartnerBookingsScreen> {
  static const _pastDays = 7;
  static const _aheadDays = 13; // members can book today + 13 days
  final _today = DateUtils.dateOnly(DateTime.now());
  late DateTime _date = _today;
  late final _strip = ScrollController(initialScrollOffset: (_pastDays - 1) * 62.0);

  @override
  void dispose() {
    _strip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final days = [for (var i = -_pastDays; i <= _aheadDays; i++) _today.add(Duration(days: i))];
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Bookings & visits'),
            Text(widget.venueName, style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
          ]),
          actions: [
            if (_date != _today)
              TextButton(onPressed: () => setState(() => _date = _today), child: const Text('Today')),
            const SizedBox(width: 4),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(128),
            child: Column(children: [
              SizedBox(
                height: 76,
                child: ListView.separated(
                  controller: _strip,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  itemCount: days.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => _DayChip(
                    day: days[i],
                    today: _today,
                    selected: days[i] == _date,
                    onTap: () => setState(() => _date = days[i]),
                  ),
                ),
              ),
              const TabBar(
                labelStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                labelColor: AppColors.text,
                unselectedLabelColor: AppColors.text2,
                indicatorColor: AppColors.primary,
                tabs: [Tab(text: 'Bookings & slots'), Tab(text: 'Check-ins')],
              ),
            ]),
          ),
        ),
        body: TabBarView(children: [
          _BookingsTab(venueId: widget.venueId, date: _date, today: _today),
          _VisitsTab(venueId: widget.venueId, date: _date),
        ]),
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.day, required this.today, required this.selected, required this.onTap});
  final DateTime day;
  final DateTime today;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isToday = day == today;
    final past = day.isBefore(today);
    return Tap(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 54,
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? AppColors.ink : (isToday ? AppColors.primary : AppColors.line)),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(isToday ? 'TODAY' : DateFormat('EEE').format(day).toUpperCase(),
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: selected ? Colors.white70 : (isToday ? AppColors.primary : AppColors.text3))),
          const SizedBox(height: 2),
          Text('${day.day}',
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : (past ? AppColors.text2 : AppColors.text))),
          Text(DateFormat('MMM').format(day),
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: selected ? Colors.white70 : AppColors.text3)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bookings & slots
// ---------------------------------------------------------------------------

typedef _DayData = ({SlotDay slots, BookingsReport bookings});

class _BookingsTab extends StatefulWidget {
  const _BookingsTab({required this.venueId, required this.date, required this.today});
  final String venueId;
  final DateTime date;
  final DateTime today;

  @override
  State<_BookingsTab> createState() => _BookingsTabState();
}

class _BookingsTabState extends State<_BookingsTab> with AutomaticKeepAliveClientMixin {
  late Future<_DayData> _future = _load();
  String? _slot; // filter by slot start
  String? _paidVia; // filter by payment

  Future<_DayData> _load() async {
    final api = context.read<PartnerSession>().api;
    final d = apiDate(widget.date);
    final r = await Future.wait([api.venueSlots(widget.venueId, date: d), api.venueBookings(widget.venueId, date: d)]);
    return (slots: r[0] as SlotDay, bookings: r[1] as BookingsReport);
  }

  Future<void> _reload() async {
    if (!mounted) return;
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // Shown by the error state.
    }
  }

  @override
  void didUpdateWidget(covariant _BookingsTab old) {
    super.didUpdateWidget(old);
    if (old.date != widget.date) {
      _slot = null;
      _future = _load();
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<_DayData>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const _GridSkeleton();
        if (snap.hasError) return RefreshFill(onRefresh: _reload, child: ErrorView(error: snap.error!, onRetry: _reload));
        return RefreshIndicator(onRefresh: _reload, child: _content(snap.data!));
      },
    );
  }

  Widget _content(_DayData data) {
    final slots = data.slots;
    final rep = data.bookings;
    final live = rep.bookings.where((b) => b.status != 'cancelled').length;
    final totalCap = slots.slots.fold<int>(0, (s, x) => s + x.capacity);
    final shown = rep.bookings
        .where((b) => (_slot == null || b.slotStart == _slot) && (_paidVia == null || b.paidVia == _paidVia))
        .toList();
    final nowHm = DateFormat('HH:mm').format(DateTime.now());
    final isToday = widget.date == widget.today;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(formatDayDate(widget.date), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 2),
            Text(
              slots.open
                  ? '$live of $totalCap spots booked · ${slots.capacity} per slot'
                  : 'Closed on this day (per your listing timings)',
              style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: MiniStat(value: '${rep.counts['booked'] ?? 0}', label: 'Upcoming', color: AppColors.blue)),
              Expanded(child: MiniStat(value: '${rep.counts['attended'] ?? 0}', label: 'Attended', color: AppColors.green)),
              Expanded(child: MiniStat(value: '${rep.counts['cancelled'] ?? 0}', label: 'Cancelled', color: AppColors.text3)),
            ]),
          ]),
        ),
        if (slots.open) ...[
          SectionTitle('Slot occupancy',
              subtitle: _slot == null ? 'Tap a slot to see who booked it' : 'Showing ${formatTimeOfDay(_slot)} — tap again to clear',
              padding: const EdgeInsets.fromLTRB(0, 22, 0, 12)),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.35,
            children: [
              for (final s in slots.slots)
                _SlotTile(
                  slot: s,
                  selected: _slot == s.start,
                  past: widget.date.isBefore(widget.today) || (isToday && s.end.compareTo(nowHm) <= 0),
                  onTap: () => setState(() => _slot = _slot == s.start ? null : s.start),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 14, runSpacing: 6, children: [
            _legend(AppColors.green, 'Open'),
            _legend(AppColors.amber, 'Filling up'),
            _legend(AppColors.red, 'Full'),
          ]),
        ],
        const SectionTitle('Bookings', padding: EdgeInsets.fromLTRB(0, 22, 0, 12)),
        SizedBox(
          height: 40,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            _filterChip(null, 'All', rep.count),
            for (final k in paidViaOrder) _filterChip(k, paidViaVisual(k).label, rep.byPaidVia[k] ?? 0),
          ]),
        ),
        const SizedBox(height: 12),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: EmptyView(
              icon: Icons.event_available_rounded,
              title: rep.bookings.isEmpty ? 'No bookings for this day' : 'No bookings match these filters',
              message: rep.bookings.isEmpty
                  ? 'Members book hourly slots in the FitKey app — up to 14 days ahead. They show up here instantly.'
                  : null,
              action: rep.bookings.isEmpty
                  ? null
                  : OutlinedButton(
                      onPressed: () => setState(() {
                            _slot = null;
                            _paidVia = null;
                          }),
                      child: const Text('Clear filters')),
            ),
          )
        else
          ..._grouped(shown),
        const SizedBox(height: 8),
        const Text('Free cancellation until 2 hours before the slot — cancelled coins or sessions go back to the member.',
            textAlign: TextAlign.center, style: TextStyle(color: AppColors.text3, fontSize: 12)),
      ],
    );
  }

  List<Widget> _grouped(List<SlotBooking> list) {
    final out = <Widget>[];
    String? last;
    for (final b in list) {
      if (b.slotStart != last) {
        last = b.slotStart;
        out.add(Padding(
          padding: EdgeInsets.only(top: out.isEmpty ? 0 : 8, bottom: 8),
          child: Text('${formatTimeOfDay(b.slotStart)} – ${formatTimeOfDay(b.slotEnd)}',
              style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.text2, fontSize: 12.5, letterSpacing: 0.2)),
        ));
      }
      out.add(Padding(padding: const EdgeInsets.only(bottom: 8), child: _BookingRow(b)));
    }
    return out;
  }

  Widget _filterChip(String? key, String label, int n) {
    final on = _paidVia == key;
    final color = key == null ? AppColors.ink : paidViaVisual(key).color;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tap(
        onTap: () => setState(() => _paidVia = key),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? color : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? color : AppColors.line),
          ),
          child: Row(children: [
            if (key != null) ...[
              Icon(paidViaVisual(key).icon, size: 15, color: on ? Colors.white : color),
              const SizedBox(width: 5),
            ],
            Text('$label · $n',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: on ? Colors.white : AppColors.text)),
          ]),
        ),
      ),
    );
  }

  Widget _legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(t, style: const TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
      ]);
}

class _SlotTile extends StatelessWidget {
  const _SlotTile({required this.slot, required this.selected, required this.past, required this.onTap});
  final SlotLoad slot;
  final bool selected;
  final bool past;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final f = slot.fill;
    final color = slot.booked >= slot.capacity && slot.capacity > 0
        ? AppColors.red
        : f >= 0.7
            ? AppColors.amber
            : AppColors.green;
    return Opacity(
      opacity: past && !selected ? 0.55 : 1,
      child: Tap(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.ink : AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? AppColors.ink : AppColors.line),
            boxShadow: selected ? null : AppShadows.soft,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(formatTimeOfDay(slot.start),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: selected ? Colors.white : AppColors.text)),
            Text.rich(TextSpan(children: [
              TextSpan(
                  text: '${slot.booked}',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: selected ? Colors.white : color)),
              TextSpan(
                  text: ' / ${slot.capacity}',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: selected ? Colors.white70 : AppColors.text3)),
            ])),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: f,
                minHeight: 5,
                backgroundColor: selected ? Colors.white24 : AppColors.surfaceAlt,
                color: color,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _BookingRow extends StatelessWidget {
  const _BookingRow(this.b);
  final SlotBooking b;

  @override
  Widget build(BuildContext context) {
    final (status, color, icon) = switch (b.status) {
      'attended' => ('Checked in', AppColors.green, Icons.check_circle_rounded),
      'cancelled' => (b.refunded ? 'Cancelled · refunded' : 'Cancelled', AppColors.text3, Icons.cancel_rounded),
      _ => ('Booked', AppColors.blue, Icons.schedule_rounded),
    };
    return AppCard(
      padding: const EdgeInsets.all(12),
      radius: 16,
      child: Row(children: [
        PersonAvatar(name: b.memberName, size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(maskedMember(b.memberName, b.phoneLast4),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    decoration: b.status == 'cancelled' ? TextDecoration.lineThrough : null,
                    color: b.status == 'cancelled' ? AppColors.text2 : AppColors.text)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              PaidViaTag(b.paidVia),
              if (b.membershipName != null)
                Text(b.membershipName!, style: const TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600))
              else if (b.costLabel != null)
                Text(b.costLabel!, style: const TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 2),
          Text(status, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
          if (b.attendedAt != null)
            Text(formatClock(b.attendedAt!), style: const TextStyle(color: AppColors.text3, fontSize: 11)),
        ]),
      ]),
    );
  }
}

class _GridSkeleton extends StatelessWidget {
  const _GridSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          const SkeletonBox(height: 120, radius: 20),
          const SizedBox(height: 26),
          const SkeletonBox(height: 18, width: 150),
          const SizedBox(height: 14),
          for (var r = 0; r < 3; r++) ...[
            const Row(children: [
              Expanded(child: SkeletonBox(height: 76, radius: 14)),
              SizedBox(width: 10),
              Expanded(child: SkeletonBox(height: 76, radius: 14)),
              SizedBox(width: 10),
              Expanded(child: SkeletonBox(height: 76, radius: 14)),
            ]),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Check-ins (visits)
// ---------------------------------------------------------------------------

class _VisitsTab extends StatefulWidget {
  const _VisitsTab({required this.venueId, required this.date});
  final String venueId;
  final DateTime date;

  @override
  State<_VisitsTab> createState() => _VisitsTabState();
}

class _VisitsTabState extends State<_VisitsTab> with AutomaticKeepAliveClientMixin {
  late Future<VisitsReport> _future = _load();

  Future<VisitsReport> _load() => context.read<PartnerSession>().api.venueVisits(widget.venueId, date: apiDate(widget.date));

  Future<void> _reload() async {
    if (!mounted) return;
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // Shown by the error state.
    }
  }

  @override
  void didUpdateWidget(covariant _VisitsTab old) {
    super.didUpdateWidget(old);
    if (old.date != widget.date) _future = _load();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<VisitsReport>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 5, itemHeight: 60);
        if (snap.hasError) return RefreshFill(onRefresh: _reload, child: ErrorView(error: snap.error!, onRetry: _reload));
        final r = snap.data!;
        if (r.visits.isEmpty) {
          return RefreshFill(
            onRefresh: _reload,
            child: EmptyView(
              icon: Icons.qr_code_scanner_rounded,
              title: 'No check-ins on ${formatDayDate(widget.date)}',
              message: 'Members check in by scanning your front-desk QR. Each visit shows how it was paid.',
            ),
          );
        }
        final keys = [...paidViaOrder, ...r.byPaidVia.keys.where((k) => !paidViaOrder.contains(k))];
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            children: [
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: MiniStat(value: '${r.count}', label: 'Check-ins')),
                    Expanded(
                        child: MiniStat(value: formatPaise(r.payoutPaise), label: 'FitKey pays you', color: AppColors.green)),
                  ]),
                  const SizedBox(height: 14),
                  SplitBar(parts: [for (final k in keys) (value: r.byPaidVia[k] ?? 0, color: paidViaVisual(k).color)]),
                  const SizedBox(height: 10),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final k in keys)
                      if ((r.byPaidVia[k] ?? 0) > 0)
                        Tag('${paidViaVisual(k).label} ${r.byPaidVia[k]}',
                            icon: paidViaVisual(k).icon, color: paidViaVisual(k).color, dense: true),
                  ]),
                ]),
              ),
              const SizedBox(height: 12),
              const NoteStrip(
                text: 'Membership visits are covered by what the member paid you. Coins, session and legacy-pass visits are paid '
                    'to you by FitKey at your per-visit rate.',
              ),
              const SizedBox(height: 14),
              for (final v in r.visits) Padding(padding: const EdgeInsets.only(bottom: 8), child: _VisitRow(v)),
            ],
          ),
        );
      },
    );
  }
}

class _VisitRow extends StatelessWidget {
  const _VisitRow(this.v);
  final VenueVisit v;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(12),
      radius: 16,
      child: Row(children: [
        PersonAvatar(name: v.memberName, size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(maskedMember(v.memberName, v.phoneLast4),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              PaidViaTag(v.paidVia),
              Tag(v.booked ? 'Booked slot' : 'Walk-in',
                  icon: v.booked ? Icons.event_available_rounded : Icons.directions_walk_rounded,
                  color: AppColors.text2,
                  bg: AppColors.surfaceAlt,
                  dense: true),
            ]),
            if (v.membershipName != null || v.costLabel != null) ...[
              const SizedBox(height: 4),
              Text(v.membershipName ?? v.costLabel!,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2, fontSize: 12)),
            ],
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(v.checkedInAt == null ? '—' : formatClock(v.checkedInAt!),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          const SizedBox(height: 2),
          if (v.payoutPaise != null && v.payoutPaise! > 0)
            Text('+${formatPaise(v.payoutPaise!)}',
                style: const TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: 12.5))
          else if (v.paidVia == 'membership')
            const Text('Membership', style: TextStyle(color: AppColors.text3, fontSize: 11.5)),
        ]),
      ]),
    );
  }
}
