import 'package:fitkey_core/fitkey_core.dart' show apiDate, formatDateTime, formatPaise, formatShortDate;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/memberships_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../bookings/paid_via.dart';

/// Direct centre members (bought this venue's own plan) and FitKey-pass visitors, kept separate.
class MembersScreen extends StatelessWidget {
  const MembersScreen({super.key, required this.venueId, required this.venueName, this.initialTab = 0});

  final String venueId;
  final String venueName;

  /// 0 = direct members, 1 = FitKey pass visitors.
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Members'),
            Text(venueName, style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
          ]),
          bottom: const TabBar(
            labelStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
            unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            labelColor: AppColors.text,
            unselectedLabelColor: AppColors.text2,
            indicatorColor: AppColors.primary,
            tabs: [Tab(text: 'Your members'), Tab(text: 'FitKey pass visitors')],
          ),
        ),
        body: TabBarView(children: [
          _DirectMembersTab(venueId: venueId),
          _FitkeyVisitorsTab(venueId: venueId),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Direct members
// ---------------------------------------------------------------------------

class _DirectMembersTab extends StatefulWidget {
  const _DirectMembersTab({required this.venueId});
  final String venueId;

  @override
  State<_DirectMembersTab> createState() => _DirectMembersTabState();
}

class _DirectMembersTabState extends State<_DirectMembersTab> with AutomaticKeepAliveClientMixin {
  static const _filters = ['active', 'upcoming', 'expired', 'all'];
  static const _labels = {'active': 'Active', 'upcoming': 'Upcoming', 'expired': 'Expired', 'all': 'All'};
  String _status = 'active';
  late Future<List<DirectMember>> _future = _load();

  Future<List<DirectMember>> _load() => context.read<PartnerSession>().api.directMembers(widget.venueId, status: _status);

  Future<void> _reload() async {
    if (!mounted) return;
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // Shown by the error state.
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(children: [
      const SizedBox(height: 12),
      ChoiceChips<String>(
        options: _filters,
        selected: _status,
        label: (s) => _labels[s]!,
        onSelected: (s) {
          if (s == _status) return;
          _status = s;
          _reload();
        },
      ),
      const SizedBox(height: 4),
      Expanded(
        child: FutureBuilder<List<DirectMember>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 5, itemHeight: 64);
            if (snap.hasError) return RefreshFill(onRefresh: _reload, child: ErrorView(error: snap.error!, onRetry: _reload));
            final list = snap.data!;
            if (list.isEmpty) {
              return RefreshFill(
                onRefresh: _reload,
                child: EmptyView(
                  icon: Icons.card_membership_rounded,
                  title: _status == 'active' ? 'No active members yet' : 'No ${_labels[_status]!.toLowerCase()} memberships',
                  message: 'Members who buy one of your approved centre plans in the FitKey app show up here with their validity and visits.',
                  action: _status == 'all'
                      ? null
                      : OutlinedButton(
                          onPressed: () {
                            _status = 'all';
                            _reload();
                          },
                          child: const Text('Show all memberships')),
                ),
              );
            }
            final revenue = list.fold<int>(0, (s, m) => s + m.amountPaise - m.commissionPaise);
            final visits = list.fold<int>(0, (s, m) => s + m.visits);
            final ending = list.where((m) => m.state == 'active' && m.daysLeft <= 7).length;
            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                children: [
                  AppCard(
                    child: Row(children: [
                      Expanded(child: MiniStat(value: '${list.length}', label: '${_labels[_status]} members')),
                      Expanded(child: MiniStat(value: '$visits', label: 'Visits', color: AppColors.blue)),
                      Expanded(
                        child: _status == 'active'
                            ? MiniStat(value: '$ending', label: 'Ending in 7 days', color: AppColors.amber)
                            : MiniStat(value: formatPaise(revenue), label: 'Net sales', color: AppColors.green),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  for (final m in list) Padding(padding: const EdgeInsets.only(bottom: 10), child: _MemberCard(m)),
                  const SizedBox(height: 4),
                  const Text('Phone numbers are masked for member privacy.',
                      textAlign: TextAlign.center, style: TextStyle(color: AppColors.text3, fontSize: 12)),
                ],
              ),
            );
          },
        ),
      ),
    ]);
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard(this.m);
  final DirectMember m;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (m.state) {
      'upcoming' => ('STARTS ${m.startsOn == null ? '' : formatShortDate(m.startsOn!).toUpperCase()}', AppColors.blue),
      'expired' => ('EXPIRED', AppColors.text3),
      'cancelled' => ('CANCELLED', AppColors.red),
      _ => (m.daysLeft <= 1 ? 'LAST DAY' : '${m.daysLeft} DAYS LEFT', m.daysLeft <= 7 ? AppColors.amber : AppColors.green),
    };
    final total = (m.startsOn != null && m.endsOn != null) ? m.endsOn!.difference(m.startsOn!).inDays + 1 : 0;
    final progress = m.state == 'active' && total > 0 ? (1 - m.daysLeft / total).clamp(0.0, 1.0) : (m.state == 'expired' ? 1.0 : 0.0);
    final limits = [
      if (m.maxVisitsPerDay != null) '${m.maxVisitsPerDay}/day',
      if (m.maxVisitsPerWeek != null) '${m.maxVisitsPerWeek}/week',
    ];

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          PersonAvatar(name: m.memberName, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(maskedMember(m.memberName, m.phoneLast4),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text('${m.planName} · ${durationLabel(m.duration)}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
            ]),
          ),
          Tag(label, color: color, dense: true),
        ]),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 5,
            backgroundColor: AppColors.surfaceAlt,
            color: color == AppColors.text3 ? AppColors.line : color,
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.date_range_rounded, size: 14, color: AppColors.text3),
          const SizedBox(width: 4),
          Text(
            m.startsOn == null || m.endsOn == null ? '—' : '${formatShortDate(m.startsOn!)} – ${formatShortDate(m.endsOn!)}',
            style: const TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Text(formatPaise(m.amountPaise), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          Tag('${m.visits} visit${m.visits == 1 ? '' : 's'}', icon: Icons.login_rounded, color: AppColors.blue, dense: true),
          if (m.lastVisitAt != null)
            Tag('Last ${formatDateTime(m.lastVisitAt!)}', icon: Icons.history_rounded, color: AppColors.text2, dense: true),
          if (limits.isNotEmpty) Tag('Max ${limits.join(' · ')}', color: AppColors.purple, dense: true),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// FitKey pass visitors
// ---------------------------------------------------------------------------

class _FitkeyVisitorsTab extends StatefulWidget {
  const _FitkeyVisitorsTab({required this.venueId});
  final String venueId;

  @override
  State<_FitkeyVisitorsTab> createState() => _FitkeyVisitorsTabState();
}

enum _Range { thisMonth, last30, lastMonth }

class _FitkeyVisitorsTabState extends State<_FitkeyVisitorsTab> with AutomaticKeepAliveClientMixin {
  _Range _range = _Range.thisMonth;
  late Future<List<FitkeyVisitor>> _future = _load();

  ({String from, String to}) get _window {
    final now = DateUtils.dateOnly(DateTime.now());
    return switch (_range) {
      _Range.thisMonth => (from: apiDate(DateTime(now.year, now.month)), to: apiDate(now)),
      _Range.last30 => (from: apiDate(now.subtract(const Duration(days: 29))), to: apiDate(now)),
      _Range.lastMonth => (
          from: apiDate(DateTime(now.year, now.month - 1)),
          to: apiDate(DateTime(now.year, now.month).subtract(const Duration(days: 1)))
        ),
    };
  }

  Future<List<FitkeyVisitor>> _load() {
    final w = _window;
    return context.read<PartnerSession>().api.fitkeyVisitors(widget.venueId, from: w.from, to: w.to);
  }

  Future<void> _reload() async {
    if (!mounted) return;
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // Shown by the error state.
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(children: [
      const SizedBox(height: 12),
      ChoiceChips<_Range>(
        options: _Range.values,
        selected: _range,
        label: (r) => switch (r) { _Range.thisMonth => 'This month', _Range.last30 => 'Last 30 days', _Range.lastMonth => 'Last month' },
        onSelected: (r) {
          if (r == _range) return;
          _range = r;
          _reload();
        },
      ),
      const SizedBox(height: 4),
      Expanded(
        child: FutureBuilder<List<FitkeyVisitor>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 5, itemHeight: 64);
            if (snap.hasError) return RefreshFill(onRefresh: _reload, child: ErrorView(error: snap.error!, onRetry: _reload));
            final list = snap.data!;
            if (list.isEmpty) {
              return RefreshFill(
                onRefresh: _reload,
                child: const EmptyView(
                  icon: Icons.qr_code_scanner_rounded,
                  title: 'No FitKey pass visits in this period',
                  message: 'Members who check in with FitKey coins, a session plan or a FitKey pass appear here. '
                      'FitKey pays you for each of these visits.',
                ),
              );
            }
            final visits = list.fold<int>(0, (s, v) => s + v.visits);
            final coins = list.fold<int>(0, (s, v) => s + v.coinsVisits);
            final session = list.fold<int>(0, (s, v) => s + v.sessionVisits);
            final legacy = list.fold<int>(0, (s, v) => s + v.legacyVisits);
            final payout = list.fold<int>(0, (s, v) => s + v.payoutPaise);
            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                children: [
                  AppCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: MiniStat(value: '${list.length}', label: 'Visitors')),
                        Expanded(child: MiniStat(value: '$visits', label: 'Visits', color: AppColors.blue)),
                        Expanded(child: MiniStat(value: formatPaise(payout), label: 'FitKey payout', color: AppColors.green)),
                      ]),
                      const SizedBox(height: 14),
                      SplitBar(parts: [
                        (value: coins, color: paidViaVisual('coins').color),
                        (value: session, color: paidViaVisual('session').color),
                        (value: legacy, color: paidViaVisual('legacy').color),
                      ]),
                      const SizedBox(height: 10),
                      Wrap(spacing: 14, runSpacing: 6, children: [
                        _legend('coins', coins),
                        _legend('session', session),
                        _legend('legacy', legacy),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  const NoteStrip(
                    text: 'These members visit on a FitKey pass, not your own membership — FitKey pays you a fixed rate per visit. '
                        'See Earnings for the monthly payout.',
                  ),
                  const SizedBox(height: 14),
                  for (final v in list) Padding(padding: const EdgeInsets.only(bottom: 10), child: _VisitorCard(v)),
                ],
              ),
            );
          },
        ),
      ),
    ]);
  }

  Widget _legend(String key, int n) {
    final v = paidViaVisual(key);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: v.color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text('${v.label} $n', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.text2)),
    ]);
  }
}

class _VisitorCard extends StatelessWidget {
  const _VisitorCard(this.v);
  final FitkeyVisitor v;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PersonAvatar(name: v.memberName, size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(maskedMember(v.memberName, v.phoneLast4),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
            if (v.lastVisitAt != null)
              Text('Last visit ${formatDateTime(v.lastVisitAt!)}',
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (v.coinsVisits > 0) _split('coins', v.coinsVisits),
              if (v.sessionVisits > 0) _split('session', v.sessionVisits),
              if (v.legacyVisits > 0) _split('legacy', v.legacyVisits),
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${v.visits}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          Text('visit${v.visits == 1 ? '' : 's'}', style: const TextStyle(color: AppColors.text3, fontSize: 11.5)),
          const SizedBox(height: 4),
          Text(formatPaise(v.payoutPaise), style: const TextStyle(color: AppColors.green, fontWeight: FontWeight.w800)),
        ]),
      ]),
    );
  }

  Widget _split(String key, int n) {
    final p = paidViaVisual(key);
    return Tag('${p.label} × $n', icon: p.icon, color: p.color, dense: true);
  }
}
