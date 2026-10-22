import 'package:fitkey_core/fitkey_core.dart' show formatClock, formatDayDate, formatNumber;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../checkin/checkin_screen.dart';
import 'log_sheets.dart';

String _dayLabel(DateTime d) {
  final today = DateUtils.dateOnly(DateTime.now());
  final day = DateUtils.dateOnly(d);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return formatDayDate(d);
}

/// Groups items by calendar day, preserving order (newest first).
List<(DateTime, List<T>)> _groupByDay<T>(List<T> items, DateTime Function(T) at) {
  final groups = <(DateTime, List<T>)>[];
  for (final item in items) {
    final day = DateUtils.dateOnly(at(item));
    if (groups.isEmpty || groups.last.$1 != day) {
      groups.add((day, [item]));
    } else {
      groups.last.$2.add(item);
    }
  }
  return groups;
}

class _DayHeader extends StatelessWidget {
  const _DayHeader(this.day, this.count, this.noun);
  final DateTime day;
  final int count;
  final String noun;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
      child: Row(children: [
        Text(_dayLabel(day), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
        const SizedBox(width: 8),
        Text('· $count $noun${count == 1 ? '' : 's'}',
            style: const TextStyle(color: AppColors.text3, fontWeight: FontWeight.w600, fontSize: 12.5)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Attendance
// ---------------------------------------------------------------------------

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  static const _pageSize = 30;
  final _items = <Checkin>[];
  int _page = 1;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = _items.isEmpty;
      _error = null;
    });
    try {
      final first = await context.read<Session>().api.myCheckins(page: 1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(first);
        _page = 1;
        _hasMore = first.length >= _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = await context.read<Session>().api.myCheckins(page: _page + 1);
      if (!mounted) return;
      setState(() {
        _page++;
        _items.addAll(next.where((c) => !_items.any((e) => e.id == c.id)));
        _hasMore = next.length >= _pageSize;
      });
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Attendance')),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const SkeletonList(count: 6, itemHeight: 64);
    if (_error != null && _items.isEmpty) return ErrorView(error: _error!, onRetry: _refresh);
    if (_items.isEmpty) {
      return RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _refresh,
        child: ListView(children: [
          EmptyView(
            icon: Icons.qr_code_scanner_rounded,
            title: 'No check-ins yet',
            message: 'Scan the QR at any FITKEY venue to start your streak.',
            action: SizedBox(
              width: 200,
              child: AppButton(
                label: 'Check in now',
                icon: Icons.qr_code_scanner_rounded,
                height: 48,
                onPressed: () => push(context, const CheckinScreen()),
              ),
            ),
          ),
        ]),
      );
    }

    final groups = _groupByDay(_items, (c) => c.checkedInAt);
    final venues = _items.map((c) => c.venueName).toSet().length;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 300) _loadMore();
        return false;
      },
      child: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (!_hasMore) Row(children: [
              Expanded(
                child: MetricTile(
                    label: 'Check-ins', value: '${_items.length}', icon: Icons.login_rounded, color: AppColors.green),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: MetricTile(
                    label: 'Days active', value: '${groups.length}', icon: Icons.calendar_month_rounded, color: AppColors.blue),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: MetricTile(label: 'Venues', value: '$venues', icon: Icons.place_rounded, color: AppColors.purple),
              ),
            ]),
            for (final g in groups) ...[
              _DayHeader(g.$1, g.$2.length, 'visit'),
              for (var i = 0; i < g.$2.length; i++) _TimelineTile(checkin: g.$2[i], last: i == g.$2.length - 1),
            ],
            if (_loadingMore)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.4))),
              )
            else if (!_hasMore)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Center(
                  child: Text("That's your whole history 💪",
                      style: TextStyle(color: AppColors.text3, fontWeight: FontWeight.w600)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.checkin, required this.last});
  final Checkin checkin;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = checkin;
    final isQr = c.method == 'qr';
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 28,
          child: Column(children: [
            const SizedBox(height: 22),
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: AppColors.green,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.greenSoft, width: 3),
              ),
            ),
            if (!last) Expanded(child: Container(width: 2, color: AppColors.line)),
          ]),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AppCard(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                const IconBubble(Icons.storefront_rounded, color: AppColors.green, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.venueName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 3),
                    Text(
                      [formatClock(c.checkedInAt), ?c.venueArea, ?c.planName].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w500),
                    ),
                  ]),
                ),
                const SizedBox(width: 8),
                Tag(
                  isQr ? 'QR' : 'OTP',
                  icon: isQr ? Icons.qr_code_2_rounded : Icons.pin_rounded,
                  color: isQr ? AppColors.blue : AppColors.purple,
                  dense: true,
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Activity log
// ---------------------------------------------------------------------------

class ActivityLogScreen extends StatefulWidget {
  const ActivityLogScreen({super.key});

  @override
  State<ActivityLogScreen> createState() => _ActivityLogScreenState();
}

class _ActivityLogScreenState extends State<ActivityLogScreen> {
  List<Activity>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _error = null);
    try {
      final items = await context.read<Session>().api.activities();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _add() async {
    if (await showActivitySheet(context)) {
      if (!mounted) return;
      toast(context, 'Activity logged');
      _reload();
    }
  }

  Future<bool> _confirmDelete(Activity a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this activity?'),
        content: Text('${a.title ?? activityVisual(a.type).label} will be removed from your progress report.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: AppColors.text2),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _delete(Activity a) async {
    final api = context.read<Session>().api;
    setState(() => _items?.removeWhere((e) => e.id == a.id));
    try {
      await api.deleteActivity(a.id);
      if (mounted) toast(context, 'Activity deleted', icon: Icons.delete_outline_rounded);
    } catch (e) {
      if (!mounted) return;
      toast(context, friendlyError(e), error: true);
      _reload(); // restore the true list
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity log')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        onPressed: _add,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Log activity', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    final items = _items;
    if (items == null) {
      return _error != null ? ErrorView(error: _error!, onRetry: _reload) : const SkeletonList(count: 6, itemHeight: 64);
    }
    if (items.isEmpty) {
      return RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _reload,
        child: ListView(children: [
          EmptyView(
            icon: Icons.bolt_rounded,
            title: 'Nothing logged yet',
            message: 'Log a workout, run or yoga session to see it in your progress report.',
            action: SizedBox(
              width: 200,
              child: AppButton(label: 'Log activity', icon: Icons.add_rounded, height: 48, onPressed: _add),
            ),
          ),
        ]),
      );
    }
    final groups = _groupByDay(items, (a) => a.loggedAt);
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 14, 4, 0),
            child: Row(children: [
              Icon(Icons.swipe_left_rounded, size: 16, color: AppColors.text3),
              SizedBox(width: 6),
              Text('Swipe left on an entry to delete it',
                  style: TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
          for (final g in groups) ...[
            _DayHeader(g.$1, g.$2.length, 'session'),
            for (final a in g.$2)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Dismissible(
                  key: ValueKey(a.id),
                  direction: DismissDirection.endToStart,
                  confirmDismiss: (_) => _confirmDelete(a),
                  onDismissed: (_) => _delete(a),
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 22),
                    decoration: BoxDecoration(color: AppColors.red, borderRadius: BorderRadius.circular(20)),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.delete_outline_rounded, color: Colors.white),
                      SizedBox(width: 6),
                      Text('Delete', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                  child: _ActivityCard(activity: a),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.activity});
  final Activity activity;

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final v = activityVisual(a.type);
    final stats = <(IconData, String)>[
      if (a.durationMin != null) (Icons.timer_outlined, '${a.durationMin} min'),
      if (a.distanceKm != null) (Icons.route_rounded, '${formatNumber(a.distanceKm!)} km'),
      if (a.calories != null) (Icons.local_fire_department_rounded, '${a.calories} kcal'),
    ];
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 58,
            height: 58,
            child: Stack(fit: StackFit.expand, children: [
              Image.asset(v.image, fit: BoxFit.cover),
              Container(color: v.color.withValues(alpha: 0.55)),
              Icon(v.icon, color: Colors.white, size: 26),
            ]),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(a.title ?? v.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ),
              Text(formatClock(a.loggedAt),
                  style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 10, runSpacing: 4, children: [
              if (a.title != null) Tag(v.label, color: v.color, bg: v.soft, dense: true),
              for (final s in stats)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(s.$1, size: 14, color: AppColors.text3),
                  const SizedBox(width: 3),
                  Text(s.$2, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w600)),
                ]),
            ]),
          ]),
        ),
      ]),
    );
  }
}
