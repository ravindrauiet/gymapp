import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/notifications_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../arena/arena_exercise_screen.dart';
import '../circles/circle_detail_screen.dart';
import '../community/contest_detail_screen.dart';
import '../explore/venue_detail_screen.dart';
import '../feed/feed_profile_screen.dart';
import '../feed/post_detail_screen.dart';
import '../trainers/trainer_detail_screen.dart';
import '../wallet/refer_earn_screen.dart';

/// Where a notification leads, from the ids in its `data`. Returns null when it has nowhere to go.
Widget? notificationTarget(AppNotification n) {
  final d = n.data;
  String? s(String k) => d[k] is String ? d[k] as String : null;
  if (s('postId') != null) return PostDetailScreen(postId: s('postId')!);
  if (s('contestId') != null) return ContestDetailScreen(contestId: s('contestId')!);
  if (s('circleId') != null) return CircleDetailScreen(circleId: s('circleId')!);
  if (s('exerciseId') != null) return ArenaExerciseScreen(exerciseId: s('exerciseId')!);
  if (n.type.startsWith('coins') || n.type.startsWith('referral')) return const ReferEarnScreen();
  if (s('venueId') != null) return VenueDetailScreen(venueId: s('venueId')!);
  if (s('trainerId') != null) return TrainerDetailScreen(trainerId: s('trainerId')!);
  if (s('userId') != null) return FeedProfileScreen(userId: s('userId')!);
  return null;
}

(IconData, Color) _look(String type) {
  if (type.contains('like')) return (Icons.favorite_rounded, AppColors.red);
  if (type.contains('comment')) return (Icons.chat_bubble_rounded, AppColors.blue);
  if (type.contains('follow')) return (Icons.person_add_alt_1_rounded, AppColors.purple);
  if (type.startsWith('coins') || type.startsWith('referral')) return (Icons.monetization_on_rounded, AppColors.amber);
  if (type.startsWith('event') || type.startsWith('contest')) return (Icons.emoji_events_rounded, AppColors.primary);
  if (type.startsWith('circle')) return (Icons.groups_rounded, AppColors.teal);
  if (type.startsWith('rating')) return (Icons.star_rounded, AppColors.amber);
  if (type.startsWith('arena')) return (Icons.sports_gymnastics_rounded, AppColors.green);
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

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final List<AppNotification> _items = [];
  bool _loading = true;
  bool _more = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reset = true}) async {
    final api = context.read<Session>().api;
    if (reset) setState(() => _loading = true);
    try {
      final r = await api.notifications(before: reset || _items.isEmpty ? null : _items.last.createdAt);
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(r.items);
        _more = r.items.length == 30;
        _loading = false;
        _error = null;
      });
      if (reset && r.unread > 0) unawaited(api.markNotificationsRead().catchError((_) {}));
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: _loading
          ? const SkeletonList(itemHeight: 52)
          : _error != null && _items.isEmpty
              ? ErrorView(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  color: AppColors.primary,
                  onRefresh: _load,
                  child: _items.isEmpty
                      ? ListView(children: const [
                          EmptyView(
                            icon: Icons.notifications_none_rounded,
                            title: 'You\'re all caught up',
                            message: 'Likes, comments, followers, coins and event updates will show up here.',
                          ),
                        ])
                      : NotificationListener<ScrollEndNotification>(
                          onNotification: (n) {
                            if (_more && n.metrics.extentAfter < 300) _load(reset: false);
                            return false;
                          },
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: _items.length,
                            separatorBuilder: (_, _) => const Divider(indent: 72, height: 1),
                            itemBuilder: (_, i) => _Tile(n: _items[i]),
                          ),
                        ),
                ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.n});
  final AppNotification n;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _look(n.type);
    final target = notificationTarget(n);
    return InkWell(
      onTap: target == null ? null : () => push(context, target),
      child: Container(
        color: n.read ? null : AppColors.primarySoft.withValues(alpha: 0.5),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconBubble(icon, color: color, size: 42),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(n.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, height: 1.3)),
              if ((n.body ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(n.body!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2, fontSize: 13)),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          Text(_ago(n.createdAt), style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

/// Bell with an unread badge; refreshes its count whenever it's rebuilt or returned to.
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  int _unread = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final n = await context.read<Session>().api.unreadNotifications();
      if (mounted) setState(() => _unread = n);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: () async {
        await push(context, const NotificationsScreen());
        _refresh();
      },
      child: Container(
        width: 44,
        height: 44,
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
    );
  }
}
