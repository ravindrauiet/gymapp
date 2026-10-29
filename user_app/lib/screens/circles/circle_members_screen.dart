import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/circles_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'circles_common.dart';

/// Members with streaks; the leader one-tap marks attendance (incl. members without a phone).
class CircleMembersScreen extends StatefulWidget {
  const CircleMembersScreen({super.key, required this.circle});
  final CircleSummary circle;

  @override
  State<CircleMembersScreen> createState() => _CircleMembersScreenState();
}

class _CircleMembersScreenState extends State<CircleMembersScreen> {
  CircleRoster? _roster;
  Object? _error;
  final _busy = <String>{};

  bool get _isLeader => widget.circle.isLeader;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<Session>().api.circleMembers(widget.circle.id);
      if (!mounted) return;
      setState(() {
        _roster = r;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _toggle(CircleMember m) async {
    final p = CirclesPrefs.instance;
    if (!(_roster?.today.isSessionDay ?? false)) {
      toast(context, p.t('noSessionMark'), error: true);
      return;
    }
    setState(() => _busy.add(m.id));
    try {
      await context.read<Session>().api.markCircleAttendance(widget.circle.id, member: m, present: !m.attendedToday);
      HapticFeedback.selectionClick();
      await _load();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(m.id));
    }
  }

  Future<void> _addOffline() async {
    final p = CirclesPrefs.instance;
    final name = TextEditingController();
    final phone = TextEditingController();
    final api = context.read<Session>().api;
    final added = await showAppSheet<bool>(
      context,
      builder: (ctx) => CirclesShell(
        child: Builder(builder: (ctx) {
          var busy = false;
          return StatefulBuilder(
            builder: (ctx, setSheet) => Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.t('addOffline'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                TextField(
                  controller: name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: p.t('offlineName')),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(labelText: p.t('offlinePhone')),
                ),
                const SizedBox(height: 18),
                AppButton(
                  label: p.t('add'),
                  icon: Icons.person_add_alt_1_rounded,
                  busy: busy,
                  onPressed: () async {
                    if (name.text.trim().length < 2) return;
                    setSheet(() => busy = true);
                    try {
                      await api.addOfflineMember(widget.circle.id,
                          name: name.text.trim(), phone: phone.text.trim().isEmpty ? null : phone.text.trim());
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      if (!ctx.mounted) return;
                      toast(ctx, friendlyError(e), error: true);
                      setSheet(() => busy = false);
                    }
                  },
                ),
              ]),
            ),
          );
        }),
      ),
    );
    name.dispose();
    phone.dispose();
    if (added == true && mounted) _load();
  }

  Future<void> _remove(CircleMember m) async {
    final p = CirclesPrefs.instance;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${p.t('remove')} ${m.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(p.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(p.t('remove'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = context.read<Session>().api;
    try {
      if (m.offline) {
        await api.removeOfflineMember(widget.circle.id, m.id);
      } else {
        await api.removeCircleMember(widget.circle.id, m.id);
      }
      await _load();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CirclesShell(child: Builder(builder: (context) {
      final p = circlesOf(context);
      final r = _roster;
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text(_isLeader ? p.t('markMembers') : p.t('membersTitle')),
          actions: const [CirclesA11yToggles(), SizedBox(width: 12)],
        ),
        bottomNavigationBar: _isLeader
            ? BottomActionBar(
                child: AppButton(label: p.t('addOffline'), icon: Icons.person_add_alt_1_rounded, onPressed: _addOffline))
            : null,
        body: r == null
            ? (_error != null ? ErrorView(error: _error!, onRetry: _load) : const SkeletonList(count: 6, itemHeight: 76))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
                  _TodayBanner(today: r.today),
                  SectionTitle('${p.t('membersTitle')} · ${r.members.length}', padding: const EdgeInsets.fromLTRB(0, 18, 0, 10)),
                  for (final m in r.members) _row(p, m),
                  if (r.offlineMembers.isNotEmpty || _isLeader) ...[
                    SectionTitle('${p.t('offlineMembers')} · ${r.offlineMembers.length}',
                        padding: const EdgeInsets.fromLTRB(0, 18, 0, 10)),
                    if (r.offlineMembers.isEmpty)
                      AppCard(
                        child: Text(p.t('markMembersSub'), style: const TextStyle(color: AppColors.text2)),
                      ),
                    for (final m in r.offlineMembers) _row(p, m),
                  ],
                ]),
              ),
      );
    }));
  }

  Widget _row(CirclesPrefs p, CircleMember m) {
    final busy = _busy.contains(m.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(children: [
          PersonAvatar(name: m.name, photoUrl: m.avatarUrl, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(m.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                if (m.isLeader) ...[const SizedBox(width: 6), Tag(p.t('leader'), dense: true)],
                if (m.offline) ...[const SizedBox(width: 6), Tag(p.t('offline'), dense: true, color: AppColors.blue)],
              ]),
              const SizedBox(height: 3),
              Text(
                '🔥 ${p.t('streakN', {'n': m.streak})} · ${p.t('thisMonth')} ${p.t('ofSessions', {'a': m.monthCount, 'b': m.monthSessions})}',
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
              ),
              if (m.phone != null) Text(m.phone!, style: const TextStyle(color: AppColors.text3, fontSize: 12)),
            ]),
          ),
          if (_isLeader) ...[
            const SizedBox(width: 8),
            SizedBox(
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: m.attendedToday ? AppColors.green : AppColors.surfaceAlt,
                  foregroundColor: m.attendedToday ? Colors.white : AppColors.text,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                onPressed: busy ? null : () => _toggle(m),
                child: busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(m.attendedToday ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 20),
                        const SizedBox(width: 6),
                        Text(m.attendedToday ? p.t('present') : p.t('absent')),
                      ]),
              ),
            ),
            if (!m.isLeader)
              PopupMenuButton<String>(
                onSelected: (_) => _remove(m),
                itemBuilder: (_) => [PopupMenuItem(value: 'remove', child: Text(p.t('remove')))],
              ),
          ] else if (m.attendedToday)
            const Icon(Icons.check_circle_rounded, color: AppColors.green),
        ]),
      ),
    );
  }
}

class _TodayBanner extends StatelessWidget {
  const _TodayBanner({required this.today});
  final CircleToday today;

  @override
  Widget build(BuildContext context) {
    final p = circlesOf(context);
    final (text, color) = switch (today.status) {
      'open' => (p.t('sessionOpen', {'time': clock12(today.closesAt)}), AppColors.green),
      'upcoming' => (p.t('sessionOpensAt', {'time': clock12(today.opensAt)}), AppColors.amber),
      'over' => (p.t('sessionOver'), AppColors.text2),
      _ => (p.t('noSessionToday'), AppColors.text2),
    };
    return AppCard(
      color: color.withValues(alpha: 0.08),
      shadow: false,
      child: Row(children: [
        Icon(Icons.today_rounded, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            [if (today.specialTitle != null) today.specialTitle!, text].join(' · '),
            style: TextStyle(fontWeight: FontWeight.w700, color: color),
          ),
        ),
      ]),
    );
  }
}
