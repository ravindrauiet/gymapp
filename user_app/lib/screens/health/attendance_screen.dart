import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import 'log_sheets.dart';

class AttendanceScreen extends StatelessWidget {
  const AttendanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Attendance history')),
      body: AsyncView<List<Checkin>>(
        future: context.read<Session>().api.myCheckins(),
        builder: (context, checkins) => checkins.isEmpty
            ? const EmptyState(
                icon: Icons.qr_code_2,
                title: 'No check-ins yet',
                message: 'Scan the QR at any FITKEY venue to start your streak.',
              )
            : ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: checkins.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final c = checkins[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    leading: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: FkColors.lime.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.login, color: FkColors.lime),
                    ),
                    title: Text(c.venueName, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(formatDateTime(c.checkedInAt)),
                    trailing: Text(c.method.toUpperCase(),
                        style: const TextStyle(fontSize: 11, color: FkColors.textSecondary)),
                  );
                },
              ),
      ),
    );
  }
}

class ActivityLogScreen extends StatefulWidget {
  const ActivityLogScreen({super.key});

  @override
  State<ActivityLogScreen> createState() => _ActivityLogScreenState();
}

class _ActivityLogScreenState extends State<ActivityLogScreen> {
  late Future<List<Activity>> _future = _load();

  Future<List<Activity>> _load() => context.read<Session>().api.activities();

  void _reload() => setState(() => _future = _load());

  Future<void> _delete(Activity a) async {
    try {
      await context.read<Session>().api.deleteActivity(a.id);
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity log')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: FkColors.lime,
        foregroundColor: Colors.black,
        onPressed: () async {
          if (await showActivitySheet(context)) _reload();
        },
        child: const Icon(Icons.add),
      ),
      body: AsyncView<List<Activity>>(
        future: _future,
        onRetry: _reload,
        builder: (context, items) => items.isEmpty
            ? const EmptyState(icon: Icons.bolt, title: 'Nothing logged yet', message: 'Tap + to log a workout or run.')
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final a = items[i];
                  final style = activityType(a.type);
                  final details = [
                    if (a.durationMin != null) '${a.durationMin} min',
                    if (a.distanceKm != null) '${formatNumber(a.distanceKm!)} km',
                    if (a.calories != null) '${a.calories} kcal',
                  ].join(' · ');
                  return Dismissible(
                    key: ValueKey(a.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      color: FkColors.danger.withValues(alpha: 0.2),
                      child: const Icon(Icons.delete_outline, color: FkColors.danger),
                    ),
                    onDismissed: (_) => _delete(a),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      leading: Icon(style.icon, color: style.color),
                      title: Text(a.title ?? style.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text([formatDateTime(a.loggedAt), details].where((s) => s.isNotEmpty).join(' · ')),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
