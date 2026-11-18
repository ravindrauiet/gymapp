part of 'partner_trainer_screen.dart';

enum _BookingView { upcoming, past }

class _BookingsTab extends StatefulWidget {
  const _BookingsTab({required this.future, required this.onReload});
  final Future<List<TrainerBookingItem>> future;
  final Future<void> Function() onReload;

  @override
  State<_BookingsTab> createState() => _BookingsTabState();
}

class _BookingsTabState extends State<_BookingsTab> with AutomaticKeepAliveClientMixin {
  _BookingView _view = _BookingView.upcoming;

  /// A day picked in the strip; null shows the whole Upcoming / Past list.
  DateTime? _day;

  /// GET /partner/trainer/calendar for the strip's 14 days (free slots, full days). Null when it failed / isn't set up.
  TrainerCalendar? _calendar;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadCalendar();
  }

  Future<void> _loadCalendar() async {
    try {
      final c = await context.read<PartnerSession>().api.trainerCalendar(from: DateUtils.dateOnly(DateTime.now()), days: 14);
      if (mounted) setState(() => _calendar = c);
    } catch (_) {
      // The calendar only adds free-slot hints; the bookings list works without it.
    }
  }

  Future<void> _reload() async {
    await Future.wait([widget.onReload(), _loadCalendar()]);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<TrainerBookingItem>>(
      future: widget.future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const SkeletonList(itemHeight: 120);
        if (snap.hasError) {
          return _RefreshableFill(onRefresh: _reload, child: ErrorView(error: snap.error!, onRetry: _reload));
        }
        final all = snap.data!;
        if (all.isEmpty) {
          return _RefreshableFill(
            onRefresh: _reload,
            child: const EmptyView(
              icon: Icons.event_available_rounded,
              title: 'No bookings yet',
              message: 'When members book a session with you in the FITKEY app, it shows up here with their contact and slot.',
            ),
          );
        }

        int byTime(TrainerBookingItem a, TrainerBookingItem b) {
          final c = a.sessionDate.compareTo(b.sessionDate);
          return c != 0 ? c : _slotMinutes(a.slotTime).compareTo(_slotMinutes(b.slotTime));
        }

        final List<TrainerBookingItem> shown;
        if (_day != null) {
          shown = all.where((b) => _sessionDay(b) == _day).toList()..sort(byTime);
        } else if (_view == _BookingView.upcoming) {
          shown = all.where(_isUpcoming).toList()..sort(byTime);
        } else {
          shown = all.where((b) => !_isUpcoming(b)).toList()..sort((a, b) => byTime(b, a));
        }

        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _DayStrip(
                bookings: all,
                calendar: _calendar,
                selected: _day,
                onSelected: (d) => setState(() => _day = d == _day ? null : d),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 8),
                child: _day != null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(children: [
                          Expanded(
                            child: Text('${formatDayDate(_day!)} · ${shown.length} session${shown.length == 1 ? '' : 's'}',
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                          ),
                          TextButton.icon(
                            onPressed: () => setState(() => _day = null),
                            icon: const Icon(Icons.close_rounded, size: 18),
                            label: const Text('Clear'),
                          ),
                        ]),
                      )
                    : ChoiceChips<_BookingView>(
                        options: _BookingView.values,
                        selected: _view,
                        onSelected: (v) => setState(() => _view = v),
                        label: (v) => v == _BookingView.upcoming
                            ? 'Upcoming · ${all.where(_isUpcoming).length}'
                            : 'Past & cancelled · ${all.where((b) => !_isUpcoming(b)).length}',
                      ),
              ),
              if (_day != null && _calendar?.dayOf(_day!) != null) _FreeSlots(day: _calendar!.dayOf(_day!)!, max: _calendar!.maxSessionsPerDay),
              if (shown.isEmpty)
                EmptyView(
                  icon: Icons.event_busy_rounded,
                  color: AppColors.text2,
                  title: _day != null ? 'Free day' : (_view == _BookingView.upcoming ? 'No upcoming sessions' : 'No past sessions'),
                  message: _day != null ? 'No sessions booked on ${formatDayDate(_day!)}.' : null,
                )
              else
                for (final b in shown)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
                    child: _BookingCard(booking: b, onChanged: _reload),
                  ),
            ],
          ),
        );
      },
    );
  }
}

/// Two weeks starting today, with a dot per booked session.
class _DayStrip extends StatelessWidget {
  const _DayStrip({required this.bookings, required this.calendar, required this.selected, required this.onSelected});
  final List<TrainerBookingItem> bookings;

  /// Marks fully booked days (max sessions per day reached) when loaded.
  final TrainerCalendar? calendar;
  final DateTime? selected;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final days = List.generate(14, (i) => DateTime(today.year, today.month, today.day + i));
    final counts = <DateTime, int>{};
    for (final b in bookings.where((b) => b.status != 'cancelled')) {
      final d = _sessionDay(b);
      if (d != null) counts[d] = (counts[d] ?? 0) + 1;
    }
    const wd = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    return SizedBox(
      height: 92,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        scrollDirection: Axis.horizontal,
        itemCount: days.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final d = days[i];
          final on = d == selected;
          final n = counts[d] ?? 0;
          return Tap(
            onTap: () => onSelected(d),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 54,
              decoration: BoxDecoration(
                color: on ? AppColors.ink : AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: on ? AppColors.ink : (i == 0 ? AppColors.primary : AppColors.line)),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(i == 0 ? 'TODAY' : wd[d.weekday - 1],
                    style: TextStyle(
                        fontSize: 9.5,
                        letterSpacing: 0.4,
                        fontWeight: FontWeight.w800,
                        color: on ? Colors.white70 : (i == 0 ? AppColors.primary : AppColors.text3))),
                const SizedBox(height: 2),
                Text('${d.day}',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: on ? Colors.white : AppColors.text)),
                const SizedBox(height: 4),
                if (calendar?.dayOf(d)?.full ?? false)
                  Text('FULL',
                      style: TextStyle(
                          fontSize: 8.5, letterSpacing: 0.4, fontWeight: FontWeight.w800, color: on ? AppColors.lime : AppColors.red))
                else
                Row(mainAxisSize: MainAxisSize.min, children: [
                  for (var k = 0; k < (n > 3 ? 3 : n); k++)
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(color: on ? AppColors.lime : AppColors.primary, shape: BoxShape.circle),
                    ),
                  if (n == 0) const SizedBox(height: 5),
                ]),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _BookingCard extends StatefulWidget {
  const _BookingCard({required this.booking, required this.onChanged});
  final TrainerBookingItem booking;

  /// Reloads the list after the session's status changed.
  final Future<void> Function() onChanged;

  @override
  State<_BookingCard> createState() => _BookingCardState();
}

class _BookingCardState extends State<_BookingCard> {
  bool _busy = false;

  /// Confirms, then POST /partner/trainer/bookings/:id/status ('completed' | 'cancelled').
  Future<void> _setStatus(String status) async {
    final b = widget.booking;
    final cancel = status == 'cancelled';
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(cancel ? 'Cancel this session?' : 'Mark session completed?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(cancel
              ? '${b.memberName} will be notified that you cancelled the ${b.slotTime} session. This can\'t be undone.'
              : 'Confirm that you took ${b.memberName}\'s ${b.slotTime} session. It then counts towards your earnings.'),
          if (cancel) ...[
            const SizedBox(height: 12),
            TextField(
              controller: note,
              maxLength: 300,
              maxLines: 2,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Message to the member (optional)'),
            ),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(cancel ? 'Keep it' : 'Not yet')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: cancel ? AppColors.red : AppColors.green),
            child: Text(cancel ? 'Cancel session' : 'Mark completed'),
          ),
        ],
      ),
    );
    final text = note.text.trim();
    note.dispose();
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<PartnerSession>().api.setTrainerBookingStatus(b.id, status, note: text.isEmpty ? null : text);
      if (!mounted) return;
      toast(context, cancel ? 'Session cancelled · member notified' : 'Session marked completed',
          icon: cancel ? Icons.event_busy_rounded : Icons.check_circle_rounded);
      await widget.onChanged();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    final mode = _mode(b.mode);
    final day = _sessionDay(b);
    final upcoming = _isUpcoming(b);
    final status = switch (b.status) {
      'cancelled' => ('Cancelled', AppColors.red, AppColors.redSoft),
      'completed' => ('Completed', AppColors.green, AppColors.greenSoft),
      _ => upcoming ? ('Confirmed', AppColors.blue, AppColors.blueSoft) : ('Session date passed', AppColors.text2, AppColors.surfaceAlt),
    };
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          PersonAvatar(name: b.memberName, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(b.memberName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 2),
              Text(
                '${day == null ? b.sessionDate : formatDayDate(day)} · ${b.slotTime}',
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ]),
          ),
          if (b.memberPhone.isNotEmpty && b.status != 'cancelled')
            IconButton.filledTonal(
              tooltip: 'Call ${b.memberName}',
              style: IconButton.styleFrom(backgroundColor: AppColors.greenSoft),
              onPressed: () => launchUrl(Uri(scheme: 'tel', path: b.memberPhone)),
              icon: const Icon(Icons.call_rounded, color: AppColors.green, size: 20),
            ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Tag(mode.$1, icon: mode.$2, color: mode.$3, bg: mode.$4, dense: true),
          const SizedBox(width: 6),
          Tag(status.$1, color: status.$2, bg: status.$3, dense: true),
          const Spacer(),
          Text(formatPaise(b.amountPaise),
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: b.status == 'cancelled' ? AppColors.text3 : AppColors.text,
                  decoration: b.status == 'cancelled' ? TextDecoration.lineThrough : null)),
        ]),
        if (b.memberPhone.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(b.memberPhone, style: const TextStyle(color: AppColors.text3, fontSize: 12)),
        ],
        if (b.status == 'confirmed') ...[
          const SizedBox(height: 10),
          if (_busy)
            const Align(
              alignment: Alignment.centerRight,
              child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
            )
          else
            Row(children: [
              TextButton(
                onPressed: () => _setStatus('cancelled'),
                style: TextButton.styleFrom(foregroundColor: AppColors.red),
                child: const Text('Cancel session'),
              ),
              const Spacer(),
              // A session can be marked done from its day on (not ahead of time).
              if (day != null && !day.isAfter(DateUtils.dateOnly(DateTime.now())))
                FilledButton.icon(
                  onPressed: () => _setStatus('completed'),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Mark completed'),
                ),
            ]),
        ],
      ]),
    );
  }
}

/// The still-free slots of the picked day (GET /partner/trainer/calendar), or "fully booked".
class _FreeSlots extends StatelessWidget {
  const _FreeSlots({required this.day, required this.max});
  final TrainerCalendarDay day;
  final int? max;

  static String _label(String t) => RegExp(r'^\d{2}:\d{2}').hasMatch(t) ? formatTimeOfDay(t) : t;

  @override
  Widget build(BuildContext context) {
    final String title;
    if (day.full) {
      title = 'Fully booked${max == null ? '' : ' · $max session${max == 1 ? '' : 's'} a day max'}';
    } else if (day.freeSlots.isEmpty) {
      title = 'No free slots in your weekly availability';
    } else {
      title = '${day.freeSlots.length} free slot${day.freeSlots.length == 1 ? '' : 's'}';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(day.full ? Icons.event_busy_rounded : Icons.event_available_rounded,
                size: 18, color: day.full ? AppColors.red : AppColors.green),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5))),
          ]),
          if (!day.full && day.freeSlots.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in day.freeSlots) Tag(_label(t), color: AppColors.green, bg: AppColors.greenSoft, dense: true),
            ]),
          ],
        ]),
      ),
    );
  }
}
