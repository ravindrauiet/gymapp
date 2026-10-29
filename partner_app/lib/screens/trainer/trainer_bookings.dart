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

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<TrainerBookingItem>>(
      future: widget.future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const SkeletonList(itemHeight: 120);
        if (snap.hasError) {
          return _RefreshableFill(onRefresh: widget.onReload, child: ErrorView(error: snap.error!, onRetry: widget.onReload));
        }
        final all = snap.data!;
        if (all.isEmpty) {
          return _RefreshableFill(
            onRefresh: widget.onReload,
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
          onRefresh: widget.onReload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _DayStrip(
                bookings: all,
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
              if (shown.isEmpty)
                EmptyView(
                  icon: Icons.event_busy_rounded,
                  color: AppColors.text2,
                  title: _day != null ? 'Free day' : (_view == _BookingView.upcoming ? 'No upcoming sessions' : 'No past sessions'),
                  message: _day != null ? 'No sessions booked on ${formatDayDate(_day!)}.' : null,
                )
              else
                for (final b in shown)
                  Padding(padding: const EdgeInsets.fromLTRB(16, 5, 16, 5), child: _BookingCard(booking: b)),
            ],
          ),
        );
      },
    );
  }
}

/// Two weeks starting today, with a dot per booked session.
class _DayStrip extends StatelessWidget {
  const _DayStrip({required this.bookings, required this.selected, required this.onSelected});
  final List<TrainerBookingItem> bookings;
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

class _BookingCard extends StatelessWidget {
  const _BookingCard({required this.booking});
  final TrainerBookingItem booking;

  @override
  Widget build(BuildContext context) {
    final b = booking;
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
      ]),
    );
  }
}
