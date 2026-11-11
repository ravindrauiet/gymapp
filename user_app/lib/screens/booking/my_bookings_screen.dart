import 'package:fitkey_core/fitkey_core.dart' show apiDate, formatDayDate, formatTimeOfDay;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/booking_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../checkin/checkin_screen.dart';
import '../explore/explore_screen.dart';
import '../explore/venue_detail_screen.dart';

/// The member's slot bookings: upcoming (with cancel) and past.
class MyBookingsScreen extends StatefulWidget {
  const MyBookingsScreen({super.key});

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends State<MyBookingsScreen> {
  String _scope = 'upcoming';
  late Future<List<SlotBooking>> _future = _load();

  Future<List<SlotBooking>> _load() => context.read<Session>().api.myBookings(scope: _scope);

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f.catchError((_) => <SlotBooking>[]);
  }

  Future<void> _cancel(SlotBooking b) async {
    final paid = b.paidVia == 'coins' || b.paidVia == 'session';
    final note = !paid
        ? 'Nothing was charged for this booking, so there is nothing to refund.'
        : b.freeCancel
            ? '${b.costLabel ?? 'Your visit'} will be returned to your FitKey pass.'
            : 'It is less than 2 hours before the slot, so ${b.costLabel ?? 'the visit'} will NOT be returned.';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(b.isRequested ? 'Withdraw this request?' : 'Cancel this booking?'),
        content: Text('${b.venueName}\n${formatDayDate(parseDay(b.slotDate))} · ${formatTimeOfDay(b.slotStart)}\n\n$note'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('Cancel booking'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await context.read<Session>().api.cancelBooking(b.id);
      if (!mounted) return;
      toast(context, r.message, icon: Icons.event_busy_rounded);
      await _refresh();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My bookings')),
      body: Column(children: [
        const SizedBox(height: 8),
        ChoiceChips<String>(
          options: const ['upcoming', 'past'],
          selected: _scope,
          label: (s) => s == 'upcoming' ? 'Upcoming' : 'Past & cancelled',
          onSelected: (s) {
            _scope = s;
            _refresh();
          },
        ),
        const SizedBox(height: 8),
        Expanded(
          child: AsyncBody<List<SlotBooking>>(
            future: _future,
            onRetry: _refresh,
            builder: (context, list) {
              if (list.isEmpty) {
                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(children: [
                    EmptyView(
                      icon: Icons.event_note_rounded,
                      title: _scope == 'upcoming' ? 'No upcoming bookings' : 'Nothing here yet',
                      message: 'Open a centre and pick a time slot — you will see the cost before you confirm.',
                      action: SizedBox(
                        width: 200,
                        child: AppButton(
                          label: 'Find a centre',
                          icon: Icons.search_rounded,
                          onPressed: () => push(context, const ExploreScreen(standalone: true)),
                        ),
                      ),
                    ),
                  ]),
                );
              }
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => _BookingCard(booking: list[i], onCancel: () => _cancel(list[i])),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// Status chip text + colour for a booking card.
(String, Color) bookingStatusLook(SlotBooking b) {
  final label = bookingStatusLabel(b.status, canCancel: b.canCancel, refunded: b.refunded);
  final color = switch (b.status) {
    'attended' => AppColors.green,
    'cancelled' => AppColors.text2,
    'requested' => AppColors.amber,
    'rejected' => AppColors.red,
    _ => b.canCancel ? AppColors.blue : AppColors.amber,
  };
  return (label, color);
}

class _BookingCard extends StatelessWidget {
  const _BookingCard({required this.booking, required this.onCancel});
  final SlotBooking booking;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final visual = venueVisual(b.venueCategories.isEmpty ? '' : b.venueCategories.first);
    final (statusLabel, statusColor) = bookingStatusLook(b);
    final isToday = b.slotDate == apiDate(DateTime.now());
    return AppCard(
      padding: const EdgeInsets.all(12),
      onTap: () => push(context, VenueDetailScreen(venueId: b.venueId)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          NetImage(b.venueCoverPhoto, fallback: visual.image, width: 72, height: 72, radius: 14),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(b.venueName,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
              const SizedBox(height: 2),
              Text('${isToday ? 'Today' : formatDayDate(parseDay(b.slotDate))} · ${formatTimeOfDay(b.slotStart)} – ${formatTimeOfDay(b.slotEnd)}',
                  style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                Tag(statusLabel, color: statusColor, dense: true),
                if (b.costLabel != null) Tag(b.costLabel!, color: AppColors.text2, icon: _paidIcon(b.paidVia), dense: true),
              ]),
            ]),
          ),
        ]),
        if (b.isRequested) ...[
          const SizedBox(height: 8),
          const Text('Request sent — the venue will confirm. We\'ll notify you.',
              style: TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ],
        if (b.status == 'rejected') ...[
          const SizedBox(height: 8),
          Text(
            [
              if ((b.rejectReason ?? '').isNotEmpty)
                'Reason: ${b.rejectReason}'
              else
                'The centre couldn\'t take this booking. Please pick another slot.',
              if (b.refunded) '${b.costLabel ?? 'Your visit'} was returned to your FitKey pass.',
            ].join('\n'),
            style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35),
          ),
        ],
        if (b.isRequested && b.canCancel) ...[
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: onCancel,
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('Withdraw request'),
          ),
        ],
        if (b.status == 'booked' && b.canCancel) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onCancel,
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.red),
                child: Text(b.freeCancel || !(b.paidVia == 'coins' || b.paidVia == 'session') ? 'Cancel' : 'Cancel (no refund)'),
              ),
            ),
            if (isToday) ...[
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => push(context, CheckinScreen(venueId: b.venueId, venueName: b.venueName)),
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                  label: const Text('Check in'),
                ),
              ),
            ],
          ]),
        ],
      ]),
    );
  }

  static IconData _paidIcon(String? via) => switch (via) {
        'coins' => Icons.toll_rounded,
        'session' => Icons.confirmation_number_rounded,
        'membership' => Icons.card_membership_rounded,
        _ => Icons.key_rounded,
      };
}

