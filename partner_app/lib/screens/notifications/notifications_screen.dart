import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/insights_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../events/partner_events_screen.dart';
import '../ratings/partner_ratings_screen.dart';
import '../trainer/partner_trainer_screen.dart';
import '../vendor/vendor_portal_screen.dart';

/// Where a partner notification leads, from its type and the ids in `data`. Null when it has nowhere to go.
Widget? partnerNotificationTarget(PartnerNotification n) {
  final d = n.data;
  String? s(String k) => d[k] is String ? d[k] as String : null;
  final t = n.type;
  if (t.startsWith('rating')) {
    if (d['trainer'] == true) return const PartnerRatingsScreen(trainer: true);
    if (s('venueId') != null) return PartnerRatingsScreen(venueId: s('venueId'));
    return const PartnerRatingsScreen();
  }
  if (t.startsWith('event') && s('contestId') != null) return PartnerEventDetailScreen(eventId: s('contestId')!);
  if (t.startsWith('trainer') || s('bookingId') != null) return const PartnerTrainerScreen();
  if (t.startsWith('vendor') || s('orderId') != null) return const VendorPortalScreen();
  if (s('contestId') != null) return PartnerEventDetailScreen(eventId: s('contestId')!);
  return null;
}

(IconData, Color) _look(String type) {
  if (type.startsWith('rating')) return (Icons.star_rounded, AppColors.amber);
  if (type.startsWith('event') || type.startsWith('contest')) return (Icons.emoji_events_rounded, AppColors.purple);
  if (type.startsWith('trainer')) return (Icons.sports_rounded, AppColors.blue);
  if (type.startsWith('vendor') || type.contains('order')) return (Icons.shopping_bag_rounded, AppColors.green);
  if (type.startsWith('venue')) return (Icons.storefront_rounded, AppColors.primary);
  return (Icons.notifications_rounded, AppColors.text2);
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${t.day}/${t.month}';
}

class PartnerNotificationsScreen extends StatefulWidget {
  const PartnerNotificationsScreen({super.key});

  @override
  State<PartnerNotificationsScreen> createState() => _PartnerNotificationsScreenState();
}

class _PartnerNotificationsScreenState extends State<PartnerNotificationsScreen> {
  final List<PartnerNotification> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _more = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reset = true}) async {
    if (!reset && (_loadingMore || !_more)) return;
    final api = context.read<PartnerSession>().api;
    setState(() {
      if (reset) {
        _loading = _items.isEmpty;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final r = await api.notifications(before: reset || _items.isEmpty ? null : _items.last.rawCreatedAt);
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(r.items);
        _more = r.items.length == 30;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
      if (reset && r.unread > 0) unawaited(api.markNotificationsRead().catchError((_) {}));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e;
      });
      if (_items.isNotEmpty) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Notifications')),
      body: _loading
          ? const SkeletonList(itemHeight: 52)
          : _error != null && _items.isEmpty
              ? ErrorView(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  color: AppColors.primary,
                  onRefresh: _load,
                  child: _items.isEmpty
                      ? ListView(children: [
                          EmptyView(
                            icon: Icons.notifications_none_rounded,
                            title: 'You\'re all caught up',
                            message: 'New ratings, event registrations, trainer bookings and store orders show up here.',
                            action: SizedBox(
                              width: 200,
                              child: OutlinedButton.icon(
                                onPressed: () => push(context, const PartnerEventsScreen()),
                                icon: const Icon(Icons.event_rounded),
                                label: const Text('Host an event'),
                              ),
                            ),
                          ),
                        ])
                      : NotificationListener<ScrollEndNotification>(
                          onNotification: (n) {
                            if (_more && n.metrics.extentAfter < 300) _load(reset: false);
                            return false;
                          },
                          child: ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                            itemCount: _items.length + (_loadingMore ? 1 : 0),
                            itemBuilder: (_, i) => i == _items.length
                                ? const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
                                  )
                                : Padding(padding: const EdgeInsets.only(bottom: 10), child: _Tile(n: _items[i])),
                          ),
                        ),
                ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.n});
  final PartnerNotification n;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _look(n.type);
    final target = partnerNotificationTarget(n);
    final stars = n.data['stars'] is num ? (n.data['stars'] as num).toInt() : null;
    return AppCard(
      onTap: target == null ? null : () => push(context, target),
      padding: const EdgeInsets.all(14),
      color: n.read ? AppColors.surface : AppColors.primarySoft,
      shadow: n.read,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconBubble(icon, color: color, size: 42, bg: n.read ? null : AppColors.surface),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, height: 1.3)),
            if (stars != null) ...[
              const SizedBox(height: 4),
              Row(children: [
                for (var i = 1; i <= 5; i++)
                  Icon(i <= stars ? Icons.star_rounded : Icons.star_outline_rounded, size: 16, color: AppColors.amber),
              ]),
            ],
            if ((n.body ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(n.body!,
                  maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2, fontSize: 13, height: 1.35)),
            ],
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_ago(n.createdAt), style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
          if (target != null) ...[
            const SizedBox(height: 10),
            const Icon(Icons.chevron_right_rounded, color: AppColors.text3, size: 20),
          ],
        ]),
      ]),
    );
  }
}

/// Bell with an unread badge for app bars; refreshes its count when returned to.
class PartnerNotificationBell extends StatefulWidget {
  const PartnerNotificationBell({super.key});

  @override
  State<PartnerNotificationBell> createState() => _PartnerNotificationBellState();
}

class _PartnerNotificationBellState extends State<PartnerNotificationBell> {
  int _unread = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    // Light polling so a new booking / order shows up while the app is open.
    _poll = Timer.periodic(const Duration(minutes: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final n = await context.read<PartnerSession>().api.unreadNotifications();
      if (mounted && n != _unread) setState(() => _unread = n);
    } catch (_) {
      // The badge is best-effort; the screen itself shows errors.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: () async {
        setState(() => _unread = 0);
        await push(context, const PartnerNotificationsScreen());
        if (mounted) _refresh();
      },
      child: Tooltip(
        message: 'Notifications',
        child: Container(
          width: 44,
          height: 44,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.line, width: 2)),
          child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
            const Icon(Icons.notifications_none_rounded, color: AppColors.ink, size: 24),
            if (_unread > 0)
              Positioned(
                top: 4,
                right: 3,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  constraints: const BoxConstraints(minWidth: 18),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Text(_unread > 99 ? '99+' : '$_unread',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
