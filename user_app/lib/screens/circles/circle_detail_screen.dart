import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/circles_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../healthstop/healthstop_screen.dart';
import '../trainers/trainers_screen.dart';
import 'circle_chat_screen.dart';
import 'circle_forms.dart';
import 'circle_leaderboard_screen.dart';
import 'circle_members_screen.dart';
import 'circle_poster_screen.dart';
import 'circle_scan_screen.dart';
import 'circles_common.dart';

class CircleDetailScreen extends StatefulWidget {
  const CircleDetailScreen({super.key, required this.circleId});
  final String circleId;

  @override
  State<CircleDetailScreen> createState() => _CircleDetailScreenState();
}

class _CircleDetailScreenState extends State<CircleDetailScreen> {
  CircleDetail? _d;
  Object? _error;
  bool _joining = false;
  bool _attending = false;
  final _rsvpBusy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<Session>().api.circle(widget.circleId);
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _join() async {
    setState(() => _joining = true);
    try {
      await context.read<Session>().api.joinCircle(widget.circleId);
      await _load();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _attend() async {
    final d = _d;
    if (d == null) return;
    setState(() => _attending = true);
    final ok = await attendHere(context, d.circle);
    if (!mounted) return;
    setState(() => _attending = false);
    if (ok) _load();
  }

  Future<void> _scan() async {
    final r = await scanCircleQr(context);
    if (r != null && mounted) _load();
  }

  Future<void> _rsvp(CircleSpecial s) async {
    setState(() => _rsvpBusy.add(s.id));
    try {
      await context.read<Session>().api.rsvpCircleSpecial(s.id, going: !s.going);
      HapticFeedback.selectionClick();
      await _load();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _rsvpBusy.remove(s.id));
    }
  }

  Future<bool> _confirm(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(title),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(CirclesPrefs.instance.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(CirclesPrefs.instance.t('confirm'))),
          ],
        ),
      ) ==
      true;

  Future<void> _menu(String action) async {
    final d = _d;
    if (d == null) return;
    final p = CirclesPrefs.instance;
    final api = context.read<Session>().api;
    switch (action) {
      case 'edit':
        final id = await push<String>(context, CircleFormScreen(existing: d.circle));
        if (id != null && mounted) _load();
      case 'leave':
        if (!await _confirm(p.t('leaveConfirm', {'name': d.circle.name})) || !mounted) return;
        try {
          await api.leaveCircle(d.circle.id);
          if (mounted) Navigator.pop(context, true);
        } catch (e) {
          if (mounted) toast(context, friendlyError(e), error: true);
        }
      case 'close':
        if (!await _confirm(p.t('closeConfirm', {'name': d.circle.name})) || !mounted) return;
        try {
          await api.closeCircle(d.circle.id);
          if (mounted) Navigator.pop(context, true);
        } catch (e) {
          if (mounted) toast(context, friendlyError(e), error: true);
        }
    }
  }

  Future<void> _deleteSpecial(CircleSpecial s) async {
    if (!await _confirm('${CirclesPrefs.instance.t('remove')} "${s.title}"?') || !mounted) return;
    try {
      await context.read<Session>().api.deleteCircleSpecial(widget.circleId, s.id);
      await _load();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CirclesShell(child: Builder(builder: (context) {
      final p = circlesOf(context);
      final d = _d;
      if (d == null) {
        return Scaffold(
          backgroundColor: AppColors.bg,
          appBar: AppBar(title: Text(p.t('circles'))),
          body: _error != null ? ErrorView(error: _error!, onRetry: _load) : const SkeletonList(count: 4, itemHeight: 120),
        );
      }
      final c = d.circle;
      final v = circleVisual(c.activity);
      return Scaffold(
        backgroundColor: AppColors.bg,
        bottomNavigationBar: c.joined
            ? null
            : BottomActionBar(
                child: AppButton(label: p.t('joinCircle'), icon: Icons.group_add_rounded, busy: _joining, onPressed: _join),
              ),
        body: RefreshIndicator(
          onRefresh: _load,
          child: CustomScrollView(slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 230,
              backgroundColor: AppColors.surface,
              actions: [
                const CirclesA11yToggles(),
                if (c.joined)
                  PopupMenuButton<String>(
                    onSelected: _menu,
                    itemBuilder: (_) => [
                      if (c.isLeader) PopupMenuItem(value: 'edit', child: Text(p.t('edit'))),
                      if (c.isLeader)
                        PopupMenuItem(value: 'close', child: Text(p.t('close')))
                      else
                        PopupMenuItem(value: 'leave', child: Text(p.t('leave'))),
                    ],
                  )
                else
                  const SizedBox(width: 12),
              ],
              flexibleSpace: FlexibleSpaceBar(
                background: Stack(fit: StackFit.expand, children: [
                  Image.asset(v.image, fit: BoxFit.cover),
                  const PhotoScrim(strength: 0.85),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        Tag(activityLabel(p, c.activity), icon: v.icon, solid: true, color: v.color),
                        if (d.circleOfTheMonth) Tag(p.t('circleOfMonth'), icon: Icons.emoji_events_rounded, solid: true, color: AppColors.amber),
                      ]),
                      const SizedBox(height: 8),
                      Text(c.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900, height: 1.15)),
                      const SizedBox(height: 4),
                      Text('${c.where}\n${scheduleLine(p, c)}',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.88), fontSize: 13.5, height: 1.35)),
                    ]),
                  ),
                ]),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              sliver: SliverList.list(children: [
                Row(children: [
                  PersonAvatar(name: c.leaderName ?? 'L', photoUrl: c.leaderAvatarUrl, size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(p.t('ledBy', {'name': c.leaderName ?? '—'}),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Tag(p.t('members', {'n': c.headcount}), icon: Icons.groups_rounded, color: AppColors.teal),
                ]),
                if (c.description != null) ...[
                  const SizedBox(height: 12),
                  Text(c.description!, style: const TextStyle(color: AppColors.text2, height: 1.45)),
                ],
                if (c.joined) ...[
                  const SizedBox(height: 16),
                  _attendanceCard(p, d),
                ],
                if (d.me != null) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: MetricTile(
                        label: p.t('streak'),
                        value: '${d.me!.streak}',
                        icon: Icons.local_fire_department_rounded,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: MetricTile(
                        label: p.t('thisMonth'),
                        value: p.t('ofSessions', {'a': d.me!.monthCount, 'b': d.me!.monthSessions}),
                        icon: Icons.event_available_rounded,
                        color: AppColors.green,
                      ),
                    ),
                  ]),
                ],
                if (c.joined) ...[
                  const SizedBox(height: 16),
                  _inviteCard(p, c),
                  const SizedBox(height: 12),
                  _actions(p, c),
                ],
                _specials(p, d),
                SectionTitle(p.t('mostRegular'), padding: const EdgeInsets.fromLTRB(0, 22, 0, 10)),
                _regularCard(p, d),
                if (d.cityRank != null) ...[
                  SectionTitle(p.t('cityRank'),
                      action: p.t('seeAll'),
                      onAction: () => push(context, CircleLeaderboardScreen(city: c.city)),
                      padding: const EdgeInsets.fromLTRB(0, 22, 0, 10)),
                  AppCard(
                    onTap: () => push(context, CircleLeaderboardScreen(city: c.city)),
                    child: Row(children: [
                      const IconBubble(Icons.emoji_events_rounded, color: AppColors.amber),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          p.t('cityRankSub', {
                            'rank': d.cityRank,
                            'total': d.cityTotal,
                            'city': c.city,
                            'rate': ((d.cityRate ?? 0) * 100).round(),
                          }),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
                    ]),
                  ),
                ],
                const SizedBox(height: 22),
                PhotoBanner(
                  image: AppImages.yoga,
                  eyebrow: 'FITKEY',
                  title: p.t('bookTrainer'),
                  subtitle: p.t('bookTrainerSub'),
                  cta: p.t('seeAll'),
                  height: 150,
                  onTap: () => push(context, const TrainersScreen()),
                ),
              ]),
            ),
          ]),
        ),
      );
    }));
  }

  Widget _attendanceCard(CirclesPrefs p, CircleDetail d) {
    final t = d.today;
    final attended = d.me?.attendedToday ?? false;
    final (status, color) = switch (t.status) {
      'open' => (p.t('sessionOpen', {'time': clock12(t.closesAt)}), AppColors.green),
      'upcoming' => (p.t('sessionOpensAt', {'time': clock12(t.opensAt)}), AppColors.amber),
      'over' => (p.t('sessionOver'), AppColors.text2),
      _ => (p.t('noSessionToday'), AppColors.text2),
    };
    final next = d.nextSession;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.today_rounded, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text([if (t.specialTitle != null) t.specialTitle!, status].join(' · '),
                style: TextStyle(fontWeight: FontWeight.w800, color: color)),
          ),
          if (t.attendeeCount > 0) Tag('${t.attendeeCount} ✓', color: AppColors.green, dense: true),
        ]),
        if (t.status != 'open' && next != null) ...[
          const SizedBox(height: 4),
          Text(
            '${p.t('nextSession')}: ${friendlyDate(p, next.date)}, ${clock12(next.startTime)}'
            '${next.specialTitle != null ? ' · ${next.specialTitle}' : ''}',
            style: const TextStyle(color: AppColors.text2),
          ),
        ],
        const SizedBox(height: 14),
        // Elder-friendly: one big button.
        SizedBox(
          height: 68,
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: attended ? AppColors.green : AppColors.primary,
              disabledBackgroundColor: attended ? AppColors.green : AppColors.surfaceAlt,
              disabledForegroundColor: attended ? Colors.white : AppColors.text3,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            onPressed: attended || t.status != 'open' || _attending ? null : _attend,
            icon: _attending
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : Icon(attended ? Icons.check_circle_rounded : Icons.touch_app_rounded, size: 28),
            label: Text(attended ? p.t('attended') : p.t('markAttendance')),
          ),
        ),
        if (!attended && t.status == 'open') ...[
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: _scan,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(p.t('scanQr')),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _inviteCard(CirclesPrefs p, CircleSummary c) => AppCard(
        color: AppColors.greenSoft,
        shadow: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.t('inviteCode'), style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                SelectableText(c.inviteCode ?? '',
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 3)),
              ]),
            ),
            IconButton(
              tooltip: p.t('copied'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: c.inviteCode ?? ''));
                if (mounted) toast(context, p.t('copied'));
              },
              icon: const Icon(Icons.copy_rounded),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: AppColors.green, minimumSize: const Size.fromHeight(48)),
                onPressed: () => shareInvite(context, c, whatsapp: true),
                icon: const Icon(Icons.chat_rounded),
                label: Text(p.t('inviteWhatsapp')),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              tooltip: p.t('shareInvite'),
              onPressed: () => shareInvite(context, c),
              icon: const Icon(Icons.share_rounded),
            ),
          ]),
        ]),
      );

  Widget _actions(CirclesPrefs p, CircleSummary c) {
    Widget tile(IconData icon, Color color, String title, String sub, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: AppCard(
            onTap: onTap,
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              IconBubble(icon, color: color, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  Text(sub, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
            ]),
          ),
        );
    return Column(children: [
      tile(Icons.forum_rounded, AppColors.teal, p.t('chat'), p.t('chatSub'), () => push(context, CircleChatScreen(circle: c))),
      if (c.isLeader) ...[
        tile(Icons.how_to_reg_rounded, AppColors.green, p.t('markMembers'), p.t('markMembersSub'),
            () => push(context, CircleMembersScreen(circle: c)).then((_) => _load())),
        tile(Icons.qr_code_2_rounded, AppColors.ink, p.t('qrPoster'), p.t('qrPosterSub'),
            () => push(context, CirclePosterScreen(circle: c))),
      ] else
        tile(Icons.groups_rounded, AppColors.blue, p.t('membersTitle'), p.t('membersSub'),
            () => push(context, CircleMembersScreen(circle: c))),
    ]);
  }

  Widget _specials(CirclesPrefs p, CircleDetail d) {
    final c = d.circle;
    if (d.specials.isEmpty && !c.isLeader) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionTitle(
        p.t('specialDays'),
        action: c.isLeader ? p.t('addSpecial') : null,
        onAction: c.isLeader
            ? () async {
                final ok = await showAddSpecialSheet(context, c);
                if (ok == true && mounted) _load();
              }
            : null,
        padding: const EdgeInsets.fromLTRB(0, 22, 0, 10),
      ),
      if (d.specials.isEmpty)
        AppCard(child: Text(p.t('noSpecials'), style: const TextStyle(color: AppColors.text2))),
      for (final s in d.specials) _specialCard(p, c, s),
    ]);
  }

  Widget _specialCard(CirclesPrefs p, CircleSummary c, CircleSpecial s) {
    final color = switch (s.kind) {
      'health_camp' => AppColors.red,
      'yoga_day' => AppColors.purple,
      'festival' => AppColors.amber,
      _ => AppColors.primary,
    };
    final icon = switch (s.kind) {
      'health_camp' => Icons.medical_services_rounded,
      'yoga_day' => Icons.self_improvement_rounded,
      'festival' => Icons.celebration_rounded,
      _ => Icons.star_rounded,
    };
    final busy = _rsvpBusy.contains(s.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        gradient: LinearGradient(colors: [color.withValues(alpha: 0.16), color.withValues(alpha: 0.04)]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            IconBubble(icon, color: color, bg: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.t('kind_${s.kind}').toUpperCase(),
                    style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1)),
                Text(s.title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                Text(
                  '${friendlyDate(p, s.date)} · ${clock12(s.startTime ?? c.startTime)} – ${clock12(s.endTime ?? c.endTime)}',
                  style: const TextStyle(color: AppColors.text2, fontSize: 13),
                ),
              ]),
            ),
            if (c.isLeader)
              IconButton(
                tooltip: p.t('remove'),
                onPressed: () => _deleteSpecial(s),
                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.text3),
              ),
          ]),
          if (s.note != null) ...[
            const SizedBox(height: 8),
            Text(s.note!, style: const TextStyle(height: 1.4)),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Text(p.t('goingN', {'n': s.rsvpCount}), style: const TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            if (c.joined)
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: s.going ? AppColors.green : color,
                  minimumSize: const Size(120, 46),
                ),
                onPressed: busy ? null : () => _rsvp(s),
                child: Text(s.going ? p.t('going') : p.t('rsvp')),
              ),
          ]),
          if (s.kind == 'health_camp') ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => push(context, const HealthStopScreen()),
              icon: const Icon(Icons.health_and_safety_rounded),
              label: Text(p.t('healthCamp')),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _regularCard(CirclesPrefs p, CircleDetail d) {
    final r = d.regularThisMonth;
    final last = d.regularLastMonth;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (r == null)
          Text(p.t('noRegular'), style: const TextStyle(color: AppColors.text2))
        else
          Row(children: [
            Stack(clipBehavior: Clip.none, children: [
              PersonAvatar(name: r.name, photoUrl: r.avatarUrl, size: 52),
              const Positioned(right: -4, bottom: -4, child: Icon(Icons.workspace_premium_rounded, color: AppColors.amber, size: 24)),
            ]),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                Text('${p.t('thisMonth')} · ${p.t('sessionsN', {'n': r.sessions})}',
                    style: const TextStyle(color: AppColors.text2)),
              ]),
            ),
          ]),
        if (last != null) ...[
          const Divider(height: 22),
          Text(p.t('mostRegularLast', {'name': last.name, 'n': last.sessions}), style: const TextStyle(color: AppColors.text2)),
        ],
      ]),
    );
  }
}
