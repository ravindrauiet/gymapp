import 'package:fitkey_core/fitkey_core.dart' show formatDate, formatDayDate, formatTimeOfDay;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../../data/memberships_api.dart' show SlotBooking;
import '../../data/partner_api.dart';
import '../../data/rse_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../bookings/paid_via.dart' show NoteStrip, PaidViaTag, maskedMember;

/// Slots & bookings (BRD §10.1): per-day slot board (total / booked / available, FitKey-pass split), booking requests
/// with accept / reject and the auto-accept switch, and blocked slots & holidays.
class SlotBoardScreen extends StatelessWidget {
  const SlotBoardScreen({super.key, required this.venueId, required this.venueName, this.initialTab = 0});

  final String venueId;
  final String venueName;

  /// 0 Slot board · 1 Requests · 2 Blocks & holidays.
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: initialTab.clamp(0, 2),
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Slots & bookings'),
              Text(
                venueName,
                style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          bottom: const TabBar(
            labelStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
            unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            labelColor: AppColors.text,
            unselectedLabelColor: AppColors.text3,
            indicatorColor: AppColors.primary,
            dividerColor: AppColors.line,
            tabs: [
              Tab(text: 'Slot board'),
              Tab(text: 'Requests'),
              Tab(text: 'Blocks'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _BoardTab(venueId: venueId),
            _RequestsTab(venueId: venueId),
            _ClosuresTab(venueId: venueId),
          ],
        ),
      ),
    );
  }
}

String _hhmm(String t) => t.length >= 5 ? t.substring(0, 5) : t;

// ---------------------------------------------------------------------------
// Board
// ---------------------------------------------------------------------------

class _BoardTab extends StatefulWidget {
  const _BoardTab({required this.venueId});
  final String venueId;

  @override
  State<_BoardTab> createState() => _BoardTabState();
}

class _BoardTabState extends State<_BoardTab> with AutomaticKeepAliveClientMixin {
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  late Future<SlotBoard> _future = _load();

  PartnerApi get _api => context.read<PartnerSession>().api;
  Future<SlotBoard> _load() => _api.slotBoard(widget.venueId, _day);

  @override
  bool get wantKeepAlive => true;

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {}
  }

  Future<void> _slotActions(BoardSlot s) async {
    final action = await showAppSheet<String>(
      context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                '${s.label} · ${formatDayDate(_day)}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            if (s.blocked)
              ListTile(
                leading: const Icon(Icons.lock_open_rounded, color: AppColors.green),
                title: const Text('Unblock this slot'),
                onTap: () => Navigator.pop(ctx, 'unblock'),
              )
            else
              ListTile(
                leading: const Icon(Icons.block_rounded, color: AppColors.red),
                title: const Text('Block this slot'),
                subtitle: s.booked > 0 ? Text('${s.booked} already booked — let them know') : null,
                onTap: () => Navigator.pop(ctx, 'block'),
              ),
            ListTile(
              leading: const Icon(Icons.beach_access_rounded, color: AppColors.amber),
              title: const Text('Mark the whole day as a holiday'),
              onTap: () => Navigator.pop(ctx, 'holiday'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      if (action == 'unblock') {
        final closures = await _api.closures(widget.venueId);
        final c = closures.where(
          (c) =>
              c.closedOn != null &&
              DateUtils.isSameDay(c.closedOn, _day) &&
              (c.wholeDay || _hhmm(c.slotStart!) == _hhmm(s.start)),
        );
        if (c.isEmpty) {
          if (mounted) toast(context, 'Remove it from the Blocks tab', icon: Icons.info_outline_rounded);
          return;
        }
        await _api.deleteClosure(widget.venueId, c.first.id);
      } else {
        final affected = await _api.addClosure(
          widget.venueId,
          on: _day,
          slotStart: action == 'block' ? _hhmm(s.start) : null,
          slotEnd: action == 'block' ? _hhmm(s.end) : null,
        );
        if (mounted) {
          toast(
            context,
            '${action == 'block' ? 'Slot blocked' : 'Holiday marked'}${affected > 0 ? ' · $affected booking${affected == 1 ? '' : 's'} to handle' : ''}',
          );
        }
      }
      if (mounted && action == 'unblock') toast(context, 'Slot reopened');
      _reload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final today = DateUtils.dateOnly(DateTime.now());
    return Column(
      children: [
        SizedBox(
          height: 74,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            scrollDirection: Axis.horizontal,
            itemCount: 14,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final d = today.add(Duration(days: i));
              final on = DateUtils.isSameDay(d, _day);
              return Tap(
                onTap: () {
                  _day = d;
                  _reload();
                },
                child: Container(
                  width: 52,
                  decoration: BoxDecoration(
                    color: on ? AppColors.ink : AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: on ? AppColors.ink : AppColors.line),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        i == 0 ? 'Today' : DateFormat('EEE').format(d),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: on ? Colors.white70 : AppColors.text3,
                        ),
                      ),
                      Text(
                        '${d.day}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: on ? Colors.white : AppColors.text,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: FutureBuilder<SlotBoard>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 6, itemHeight: 72);
              if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
              final b = snap.data!;
              return RefreshIndicator(
                onRefresh: _reload,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                  children: [
                    AppCard(
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                      child: Row(
                        children: [
                          _cell('${b.total}', 'Total'),
                          _cell('${b.booked}', 'Booked', AppColors.blue),
                          _cell('${b.passBooked}', 'FitKey pass', AppColors.primary),
                          _cell('${b.available}', 'Available', AppColors.green),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    const NoteStrip(text: 'Tap a slot to block it or mark the day as a holiday.'),
                    const SizedBox(height: 12),
                    if (b.slots.isEmpty)
                      const EmptyView(
                        icon: Icons.event_busy_rounded,
                        title: 'No slots this day',
                        message: 'Closed, a holiday, or slot timings not set in your listing.',
                      )
                    else
                      for (final s in b.slots)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _SlotRow(slot: s, onTap: () => _slotActions(s)),
                        ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _cell(String v, String l, [Color c = AppColors.text]) => Expanded(
    child: Column(
      children: [
        Text(
          v,
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: c),
        ),
        Text(
          l,
          style: const TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class _SlotRow extends StatelessWidget {
  const _SlotRow({required this.slot, required this.onTap});
  final BoardSlot slot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = slot;
    final cap = s.capacity <= 0 ? 1 : s.capacity;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      color: s.blocked ? AppColors.surfaceAlt : AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${formatTimeOfDay(s.start)} – ${formatTimeOfDay(s.end)}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              const Spacer(),
              if (s.blocked)
                const Tag('BLOCKED', color: AppColors.red, dense: true)
              else
                Text(
                  '${s.available} left',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: s.available == 0 ? AppColors.red : AppColors.green,
                    fontSize: 13,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  if (s.passBooked > 0)
                    Expanded(
                      flex: s.passBooked,
                      child: Container(color: AppColors.primary),
                    ),
                  if (s.ownBooked > 0)
                    Expanded(
                      flex: s.ownBooked,
                      child: Container(color: AppColors.blue),
                    ),
                  if (cap - s.booked > 0)
                    Expanded(
                      flex: cap - s.booked,
                      child: Container(color: AppColors.surfaceAlt),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${s.booked}/${s.capacity} booked',
                style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600, fontSize: 12.5),
              ),
              Tag(
                'FitKey pass ${s.passBooked}${s.passCap == null ? '' : '/${s.passCap}'}',
                color: AppColors.primary,
                dense: true,
              ),
              if (s.passBlocked) const Tag('No FitKey pass', color: AppColors.amber, dense: true),
              if (s.ladiesOnly) const Tag('Ladies only', color: AppColors.pink, dense: true),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

class _RequestsTab extends StatefulWidget {
  const _RequestsTab({required this.venueId});
  final String venueId;

  @override
  State<_RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends State<_RequestsTab> with AutomaticKeepAliveClientMixin {
  late Future<List<SlotBooking>> _future = _load();
  bool? _autoAccept;
  final _busy = <String>{};

  PartnerApi get _api => context.read<PartnerSession>().api;
  Future<List<SlotBooking>> _load() async {
    final r = await _api.bookingRequests(widget.venueId);
    if (mounted) setState(() => _autoAccept = r.autoAccept);
    return r.requests;
  }

  @override
  bool get wantKeepAlive => true;

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {}
  }

  Future<void> _setAuto(bool v) async {
    final old = _autoAccept;
    setState(() => _autoAccept = v);
    try {
      await _api.setAutoAccept(widget.venueId, v);
      if (mounted) toast(context, v ? 'New bookings are accepted automatically' : 'You\'ll approve each booking');
    } catch (e) {
      if (mounted) {
        setState(() => _autoAccept = old);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  Future<void> _decide(SlotBooking b, bool accept) async {
    String? reason;
    if (!accept) {
      reason = await _askReason();
      if (reason == null) return;
    }
    setState(() => _busy.add(b.id));
    try {
      accept ? await _api.acceptBooking(b.id) : await _api.rejectBooking(b.id, reason: reason!.isEmpty ? null : reason);
      if (mounted) toast(context, accept ? 'Booking accepted' : 'Booking rejected — member notified');
      await _reload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(b.id));
    }
  }

  /// Returns the typed reason ('' allowed) or null when cancelled.
  Future<String?> _askReason() {
    final c = TextEditingController();
    const quick = ['Slot full', 'Venue closed', 'Maintenance', 'Trainer unavailable'];
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Reject booking?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final q in quick) ActionChip(label: Text(q), onPressed: () => set(() => c.text = q))],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: c,
                decoration: const InputDecoration(labelText: 'Reason (shown to the member)'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Reject', style: TextStyle(color: AppColors.red)),
            ),
          ],
        ),
      ),
    ).whenComplete(c.dispose);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<SlotBooking>>(
      future: _future,
      builder: (context, snap) {
        final auto = AppCard(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _autoAccept ?? true,
            onChanged: _autoAccept == null ? null : _setAuto,
            title: const Text('Auto-accept bookings', style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('Off: each booking waits for you to accept'),
          ),
        );
        if (snap.connectionState != ConnectionState.done) {
          return ListView(padding: const EdgeInsets.all(16), children: [auto, const SizedBox(height: 200)]);
        }
        if (snap.hasError) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              auto,
              ErrorView(error: snap.error!, onRetry: _reload),
            ],
          );
        }
        final reqs = snap.data!;
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              auto,
              const SizedBox(height: 12),
              if (reqs.isEmpty)
                const EmptyView(
                  icon: Icons.inbox_rounded,
                  title: 'No pending requests',
                  message: 'New booking requests show up here.',
                )
              else
                for (final b in reqs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: AppCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              PersonAvatar(name: b.memberName, size: 38),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      maskedMember(b.memberName, b.phoneLast4),
                                      style: const TextStyle(fontWeight: FontWeight.w800),
                                    ),
                                    Text(
                                      '${b.slotDate == null ? '' : '${formatDayDate(b.slotDate!)} · '}'
                                      '${formatTimeOfDay(b.slotStart)} – ${formatTimeOfDay(b.slotEnd)}',
                                      style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                                    ),
                                  ],
                                ),
                              ),
                              if (b.paidVia != null) PaidViaTag(b.paidVia),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: _busy.contains(b.id) ? null : () => _decide(b, false),
                                  child: const Text('Reject', style: TextStyle(color: AppColors.red)),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton(
                                  onPressed: _busy.contains(b.id) ? null : () => _decide(b, true),
                                  child: const Text('Accept'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Closures (blocked slots & holidays)
// ---------------------------------------------------------------------------

class _ClosuresTab extends StatefulWidget {
  const _ClosuresTab({required this.venueId});
  final String venueId;

  @override
  State<_ClosuresTab> createState() => _ClosuresTabState();
}

class _ClosuresTabState extends State<_ClosuresTab> with AutomaticKeepAliveClientMixin {
  late Future<List<VenueClosure>> _future = _load();

  PartnerApi get _api => context.read<PartnerSession>().api;
  Future<List<VenueClosure>> _load() => _api.closures(widget.venueId);

  @override
  bool get wantKeepAlive => true;

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {}
  }

  Future<void> _add() async {
    final added = await showAppSheet<bool>(context, builder: (_) => _ClosureSheet(venueId: widget.venueId));
    if (added == true) _reload();
  }

  Future<void> _remove(VenueClosure c) async {
    try {
      await _api.deleteClosure(widget.venueId, c.id);
      if (mounted) toast(context, 'Removed');
      _reload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'closure',
        onPressed: _add,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Block / holiday'),
      ),
      body: FutureBuilder<List<VenueClosure>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 3, itemHeight: 64);
          if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
          final list = snap.data!;
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                if (list.isEmpty)
                  const EmptyView(
                    icon: Icons.event_available_rounded,
                    title: 'No blocks or holidays',
                    message:
                        'Block a slot for maintenance or mark a festival holiday. Members can\'t book those times.',
                  )
                else
                  for (final c in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: AppCard(
                        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                        child: Row(
                          children: [
                            IconBubble(
                              c.wholeDay ? Icons.beach_access_rounded : Icons.block_rounded,
                              color: c.wholeDay ? AppColors.amber : AppColors.red,
                              size: 40,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c.closedOn == null ? 'Date not set' : formatDate(c.closedOn!),
                                    style: const TextStyle(fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    [
                                      c.wholeDay
                                          ? 'Whole day (holiday)'
                                          : '${formatTimeOfDay(c.slotStart)} – ${formatTimeOfDay(c.slotEnd)}',
                                      ?c.note,
                                    ].join(' · '),
                                    style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              onPressed: () => _remove(c),
                              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.text3),
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

class _ClosureSheet extends StatefulWidget {
  const _ClosureSheet({required this.venueId});
  final String venueId;

  @override
  State<_ClosureSheet> createState() => _ClosureSheetState();
}

class _ClosureSheetState extends State<_ClosureSheet> {
  bool _holiday = true;
  DateTime _day = DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 1));
  TimeOfDay _from = const TimeOfDay(hour: 18, minute: 0);
  TimeOfDay _to = const TimeOfDay(hour: 20, minute: 0);
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String _fmt(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    if (!_holiday && (_to.hour * 60 + _to.minute) <= (_from.hour * 60 + _from.minute)) {
      toast(context, 'End time must be after the start time', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<PartnerSession>().api.addClosure(
        widget.venueId,
        on: _day,
        slotStart: _holiday ? null : _fmt(_from),
        slotEnd: _holiday ? null : _fmt(_to),
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Future<void> pickTime(bool from) async {
      final t = await showTimePicker(context: context, initialTime: from ? _from : _to);
      if (t != null) setState(() => from ? _from = t : _to = t);
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Block a slot or mark a holiday', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Holiday'), icon: Icon(Icons.beach_access_rounded)),
                ButtonSegment(value: false, label: Text('Block slot'), icon: Icon(Icons.block_rounded)),
              ],
              selected: {_holiday},
              onSelectionChanged: (s) => setState(() => _holiday = s.first),
            ),
            const SizedBox(height: 14),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today_rounded),
              title: Text(formatDate(_day), style: const TextStyle(fontWeight: FontWeight.w700)),
              trailing: const Text('Change'),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _day,
                  firstDate: DateUtils.dateOnly(DateTime.now()),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (d != null) setState(() => _day = d);
              },
            ),
            if (!_holiday)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => pickTime(true),
                      icon: const Icon(Icons.schedule_rounded),
                      label: Text('From ${_from.format(context)}'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => pickTime(false),
                      icon: const Icon(Icons.schedule_rounded),
                      label: Text('To ${_to.format(context)}'),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'e.g. Diwali'),
            ),
            const SizedBox(height: 16),
            AppButton(label: _holiday ? 'Mark holiday' : 'Block slot', busy: _busy, onPressed: _save),
          ],
        ),
      ),
    );
  }
}
