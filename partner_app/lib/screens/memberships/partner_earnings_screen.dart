import 'package:fitkey_core/fitkey_core.dart' show formatPaise;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../../data/memberships_api.dart';
import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../bookings/paid_via.dart';

/// Venue earnings: direct membership sales (minus FitKey commission) + FitKey-pass visit payouts, with a 12-month
/// payout statement. All own venues by default, or one venue when [venueId] is given.
class PartnerEarningsScreen extends StatefulWidget {
  const PartnerEarningsScreen({super.key, this.venueId});

  final String? venueId;

  @override
  State<PartnerEarningsScreen> createState() => _PartnerEarningsScreenState();
}

typedef _Data = ({EarningsReport month, PayoutStatement statement, List<VenueListItem> venues});

class _PartnerEarningsScreenState extends State<PartnerEarningsScreen> {
  final _thisMonth = DateTime(DateTime.now().year, DateTime.now().month);
  late DateTime _month = _thisMonth;
  late String? _venueId = widget.venueId;
  late Future<_Data> _future = _load();

  static String _key(DateTime m) => DateFormat('yyyy-MM').format(m);

  Future<_Data> _load() async {
    final api = context.read<PartnerSession>().api;
    final r = await Future.wait<Object>([
      api.partnerEarnings(venueId: _venueId, month: _key(_month)),
      api.payoutStatement(venueId: _venueId),
      api.venues(),
    ]);
    return (month: r[0] as EarningsReport, statement: r[1] as PayoutStatement, venues: r[2] as List<VenueListItem>);
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

  void _setMonth(DateTime m) {
    if (m.isAfter(_thisMonth)) return;
    _month = m;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Venue earnings')),
      body: FutureBuilder<_Data>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const _Skeleton();
          if (snap.hasError) return RefreshFill(onRefresh: _reload, child: ErrorView(error: snap.error!, onRetry: _reload));
          return RefreshIndicator(onRefresh: _reload, child: _content(snap.data!));
        },
      ),
    );
  }

  Widget _content(_Data d) {
    final e = d.month;
    final pcts = e.venues.map((v) => v.commissionPct).toSet();
    final pctLabel = pcts.length == 1 ? _pct(pcts.first) : 'per venue';
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 28),
      children: [
        if (d.venues.length > 1)
          ChoiceChips<String?>(
            options: [null, ...d.venues.map((v) => v.id)],
            selected: _venueId,
            label: (id) => id == null ? 'All venues' : d.venues.firstWhere((v) => v.id == id).name,
            icon: (id) => id == null ? Icons.apps_rounded : Icons.storefront_rounded,
            onSelected: (id) {
              if (id == _venueId) return;
              _venueId = id;
              _reload();
            },
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (e.isMock)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: NoteStrip(
                  icon: Icons.science_outlined,
                  color: AppColors.amber,
                  text: 'Payments are in test mode — no money has moved yet. These figures show what FitKey would pay you '
                      'once live payments and payouts are switched on.',
                ),
              ),
            _MonthPicker(
              month: _month,
              canNext: _month.isBefore(_thisMonth),
              onPrev: () => _setMonth(DateTime(_month.year, _month.month - 1)),
              onNext: () => _setMonth(DateTime(_month.year, _month.month + 1)),
            ),
            const SizedBox(height: 12),
            _Hero(e: e, month: _month),
            const SectionTitle('Membership sales', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
            AppCard(
              child: Column(children: [
                _line(Icons.card_membership_rounded, AppColors.primary, 'Memberships sold', '${e.membershipsSold}'),
                const Divider(height: 22),
                _line(Icons.payments_rounded, AppColors.text2, 'Gross sales', formatPaise(e.membershipGrossPaise)),
                const SizedBox(height: 10),
                _line(Icons.percent_rounded, AppColors.red, 'FitKey commission ($pctLabel)', '− ${formatPaise(e.commissionPaise)}',
                    valueColor: AppColors.red),
                const Divider(height: 22),
                _line(Icons.account_balance_wallet_rounded, AppColors.green, 'Net to you', formatPaise(e.membershipNetPaise),
                    bold: true, valueColor: AppColors.green),
                if (e.membershipVisits > 0) ...[
                  const SizedBox(height: 12),
                  Text('${e.membershipVisits} visit${e.membershipVisits == 1 ? '' : 's'} by your members — included in their membership',
                      style: const TextStyle(color: AppColors.text3, fontSize: 12)),
                ],
              ]),
            ),
            const SectionTitle('FitKey pass visits', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
            AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: MiniStat(value: '${e.fitkeyVisits}', label: 'Paid visits')),
                  Expanded(child: MiniStat(value: formatPaise(e.visitPayoutPaise), label: 'Visit payouts', color: AppColors.green)),
                ]),
                const SizedBox(height: 14),
                SplitBar(parts: [
                  (value: e.coinsVisits, color: paidViaVisual('coins').color),
                  (value: e.sessionVisits, color: paidViaVisual('session').color),
                  (value: e.legacyVisits, color: paidViaVisual('legacy').color),
                ]),
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final (k, n) in [('coins', e.coinsVisits), ('session', e.sessionVisits), ('legacy', e.legacyVisits)])
                    Tag('${paidViaVisual(k).label} $n', icon: paidViaVisual(k).icon, color: paidViaVisual(k).color, dense: true),
                ]),
                if (e.venues.isNotEmpty) ...[
                  const Divider(height: 26),
                  const Text('Your rates', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  for (final v in e.venues)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        Expanded(
                          child: Text(v.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2)),
                        ),
                        Text('${formatPaise(v.payoutPerVisitPaise)}/visit · ${_pct(v.commissionPct)} fee',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                      ]),
                    ),
                ],
              ]),
            ),
            SectionTitle('Payout statement',
                subtitle: 'Last ${d.statement.months.length} months · tap a month to open it',
                padding: const EdgeInsets.fromLTRB(0, 24, 0, 12)),
            AppCard(
              padding: const EdgeInsets.fromLTRB(10, 16, 10, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(height: 180, child: _StatementChart(months: d.statement.months.reversed.toList())),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Wrap(spacing: 14, children: [
                    _legend(AppColors.primary, 'Memberships (net)'),
                    _legend(AppColors.blue, 'FitKey visits'),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            _StatementTable(
              statement: d.statement,
              selected: _key(_month),
              onTap: (m) => _setMonth(m.monthStart),
            ),
            const SizedBox(height: 16),
            Text(
              e.isMock
                  ? 'Test mode: payouts are calculated but not transferred. Memberships are non-refundable; FitKey-pass visits '
                      'are counted at check-in.'
                  : 'Payouts are settled monthly to your registered bank account.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.text3, fontSize: 12),
            ),
          ]),
        ),
      ],
    );
  }

  static String _pct(double v) => '${v % 1 == 0 ? v.toInt() : v.toStringAsFixed(1)}%';

  Widget _line(IconData i, Color c, String label, String value, {bool bold = false, Color? valueColor}) => Row(children: [
        IconBubble(i, color: c, size: 34, iconSize: 17),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600))),
        Text(value, style: TextStyle(fontWeight: FontWeight.w800, fontSize: bold ? 16 : 14, color: valueColor ?? AppColors.text)),
      ]);

  Widget _legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(t, style: const TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
      ]);
}

class _MonthPicker extends StatelessWidget {
  const _MonthPicker({required this.month, required this.canNext, required this.onPrev, required this.onNext});
  final DateTime month;
  final bool canNext;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      radius: 16,
      child: Row(children: [
        IconButton(tooltip: 'Previous month', onPressed: onPrev, icon: const Icon(Icons.chevron_left_rounded)),
        Expanded(
          child: Column(children: [
            Text(DateFormat('MMMM yyyy').format(month), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            Text(canNext ? 'Closed month' : 'This month so far',
                style: const TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w600)),
          ]),
        ),
        IconButton(
          tooltip: 'Next month',
          onPressed: canNext ? onNext : null,
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ]),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.e, required this.month});
  final EarningsReport e;
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(gradient: AppColors.passGradient, borderRadius: BorderRadius.circular(22), boxShadow: AppShadows.card),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('TOTAL PAYABLE TO YOU',
              style: TextStyle(color: AppColors.lime, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
          const Spacer(),
          if (e.isMock)
            Tag('TEST MODE', color: Colors.white, bg: Colors.white.withValues(alpha: 0.14), dense: true),
        ]),
        const SizedBox(height: 6),
        Text(formatPaise(e.totalPayablePaise),
            style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
        const SizedBox(height: 4),
        Text('${DateFormat('MMMM yyyy').format(month)} · memberships net + FitKey visit payouts',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12.5)),
        const SizedBox(height: 16),
        SplitBar(parts: [
          (value: e.membershipNetPaise, color: AppColors.primary),
          (value: e.visitPayoutPaise, color: AppColors.blue),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _part(AppColors.primary, 'Memberships', formatPaise(e.membershipNetPaise))),
          Expanded(child: _part(AppColors.blue, 'FitKey visits', formatPaise(e.visitPayoutPaise))),
        ]),
      ]),
    );
  }

  Widget _part(Color c, String label, String value) => Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '$label  ', style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
              TextSpan(text: value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]);
}

class _StatementChart extends StatelessWidget {
  const _StatementChart({required this.months});

  /// Oldest month first.
  final List<EarningsMonth> months;

  @override
  Widget build(BuildContext context) {
    final maxV = months.fold<int>(0, (a, m) => m.totalPayablePaise > a ? m.totalPayablePaise : a);
    final maxY = maxV <= 0 ? 100.0 : maxV / 100 * 1.15;
    const axis = TextStyle(color: AppColors.text3, fontSize: 10, fontWeight: FontWeight.w600);
    return BarChart(BarChartData(
      maxY: maxY,
      alignment: BarChartAlignment.spaceAround,
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => AppColors.ink,
          tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          getTooltipItem: (group, _, _, _) {
            final m = months[group.x];
            return BarTooltipItem(
              '${DateFormat('MMM yyyy').format(m.monthStart)}\n',
              const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
              children: [
                TextSpan(
                  text: formatPaise(m.totalPayablePaise),
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800),
                ),
              ],
            );
          },
        ),
      ),
      titlesData: FlTitlesData(
        leftTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        topTitles: const AxisTitles(),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            getTitlesWidget: (v, _) {
              final i = v.toInt();
              if (i < 0 || i >= months.length) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(DateFormat('MMM').format(months[i].monthStart).substring(0, 1), style: axis),
              );
            },
          ),
        ),
      ),
      barGroups: [
        for (var i = 0; i < months.length; i++)
          BarChartGroupData(x: i, barRods: [
            BarChartRodData(
              toY: months[i].totalPayablePaise / 100,
              width: 14,
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              rodStackItems: [
                BarChartRodStackItem(0, months[i].membershipNetPaise / 100, AppColors.primary),
                BarChartRodStackItem(months[i].membershipNetPaise / 100, months[i].totalPayablePaise / 100, AppColors.blue),
              ],
              backDrawRodData: BackgroundBarChartRodData(show: true, toY: maxY, color: AppColors.bg),
            ),
          ]),
      ],
    ));
  }
}

class _StatementTable extends StatelessWidget {
  const _StatementTable({required this.statement, required this.selected, required this.onTap});
  final PayoutStatement statement;
  final String selected;
  final ValueChanged<EarningsMonth> onTap;

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(color: AppColors.text3, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.4);
    final t = statement.totals;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(children: [
            Expanded(flex: 3, child: Text('MONTH', style: head)),
            Expanded(flex: 3, child: Text('MEMBERSHIPS', style: head, textAlign: TextAlign.right)),
            Expanded(flex: 3, child: Text('VISITS', style: head, textAlign: TextAlign.right)),
            Expanded(flex: 3, child: Text('TOTAL', style: head, textAlign: TextAlign.right)),
          ]),
        ),
        const Divider(height: 1),
        for (final m in statement.months)
          InkWell(
            onTap: () => onTap(m),
            child: Container(
              color: m.month == selected ? AppColors.primarySoft : null,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                Expanded(
                  flex: 3,
                  child: Text(DateFormat('MMM yy').format(m.monthStart), style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  flex: 3,
                  child: _cell(formatPaise(m.membershipNetPaise), '${m.membershipsSold} sold'),
                ),
                Expanded(flex: 3, child: _cell(formatPaise(m.visitPayoutPaise), '${m.fitkeyVisits} visits')),
                Expanded(
                  flex: 3,
                  child: Text(formatPaise(m.totalPayablePaise),
                      textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Row(children: [
            const Expanded(flex: 3, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w800))),
            Expanded(flex: 3, child: _cell(formatPaise(t['membershipNetPaise'] ?? 0), '${t['membershipsSold'] ?? 0} sold')),
            Expanded(flex: 3, child: _cell(formatPaise(t['visitPayoutPaise'] ?? 0), '${t['fitkeyVisits'] ?? 0} visits')),
            Expanded(
              flex: 3,
              child: Text(formatPaise(t['totalPayablePaise'] ?? 0),
                  textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.green)),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _cell(String top, String bottom) => Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(top, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        Text(bottom, maxLines: 1, style: const TextStyle(color: AppColors.text3, fontSize: 11)),
      ]);
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: const [
          SkeletonBox(height: 60, radius: 16),
          SizedBox(height: 12),
          SkeletonBox(height: 170, radius: 22),
          SizedBox(height: 28),
          SkeletonBox(height: 18, width: 160),
          SizedBox(height: 12),
          SkeletonBox(height: 180, radius: 20),
        ],
      ),
    );
  }
}
