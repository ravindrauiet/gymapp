import 'package:fitkey_core/fitkey_core.dart' show formatPaise, formatShortDate;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../../data/brd_api.dart';
import '../../data/models.dart';
import '../../data/rse_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../../widgets/commission_plan_card.dart';
import '../home/shell.dart';
import '../home/venue_tab_body.dart' show TabSection;
import '../memberships/partner_earnings_screen.dart';
import '../notifications/notifications_screen.dart';
import '../trainer/partner_trainer_screen.dart';
import '../vendor/vendor_portal_screen.dart';
import 'pass_visits_screen.dart';
import 'payouts_screen.dart';

enum EarnPeriod {
  today('Today'),
  week('This week'),
  month('This month'),
  lastMonth('Last month');

  const EarnPeriod(this.label);
  final String label;

  /// Inclusive [from, to] dates for the period, relative to [now]. Weeks start on Monday.
  (DateTime, DateTime) range([DateTime? now]) {
    final n = now ?? DateTime.now();
    final d = DateTime(n.year, n.month, n.day);
    return switch (this) {
      today => (d, d),
      week => (d.subtract(Duration(days: d.weekday - 1)), d),
      month => (DateTime(d.year, d.month), d),
      lastMonth => (DateTime(d.year, d.month - 1), DateTime(d.year, d.month, 0)),
    };
  }
}

Color earningSourceColor(String source) => switch (source) {
  'fitkey_pass' => AppColors.primary,
  'fitkey_direct' => AppColors.purple,
  'self' || 'walk_in' => AppColors.blue,
  'fitpass' => AppColors.teal,
  _ => AppColors.text2,
};

IconData earningSourceIcon(String source) => switch (source) {
  'fitkey_pass' => Icons.qr_code_2_rounded,
  'fitkey_direct' => Icons.card_membership_rounded,
  'self' || 'walk_in' => Icons.storefront_rounded,
  'fitpass' => Icons.confirmation_number_rounded,
  _ => Icons.more_horiz_rounded,
};

/// Earn (BRD §10.3): live earnings by period and source, per-day chart, per-visit detail for FitKey pass users,
/// deductions (commission per the plan year; GST only on own-pass / direct sales), payouts and GST invoices.
class EarnTab extends StatefulWidget {
  const EarnTab({super.key});

  @override
  State<EarnTab> createState() => _EarnTabState();
}

class _EarnTabState extends State<EarnTab> {
  EarnPeriod _period = EarnPeriod.month;
  String? _venueId;
  late Future<EarningsBreakdown> _future = _load();

  Future<EarningsBreakdown> _load() {
    final (from, to) = _period.range();
    return context.read<PartnerSession>().api.earningsBreakdown(
      from: from,
      to: to,
      venueId: _venueId,
      type: PartnerShell.of(context).type,
    );
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final shell = PartnerShell.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Earn'), actions: const [PartnerNotificationBell(), SizedBox(width: 4)]),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const SizedBox(height: 12),
            ChoiceChips<EarnPeriod>(
              options: EarnPeriod.values,
              selected: _period,
              onSelected: (p) {
                _period = p;
                _reload();
              },
              label: (p) => p.label,
            ),
            if (shell.type.isVenue)
              FutureBuilder<List<VenueListItem>>(
                future: shell.venues,
                builder: (context, snap) => VenueSwitcher(
                  venues: snap.data ?? const [],
                  selected: _venueId,
                  allLabel: 'All venues',
                  onSelected: (id) {
                    _venueId = id;
                    _reload();
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: FutureBuilder<EarningsBreakdown>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Shimmer(
                      child: Column(
                        children: [
                          SkeletonBox(height: 150, radius: 22),
                          SizedBox(height: 14),
                          SkeletonBox(height: 220, radius: 20),
                        ],
                      ),
                    );
                  }
                  if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
                  return _Breakdown(data: snap.data!, period: _period, venueId: _venueId);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TabSection('Payouts'),
                  ToolRow(
                    icon: Icons.account_balance_rounded,
                    color: AppColors.green,
                    title: 'Payouts',
                    subtitle: 'Schedule, status and statements',
                    onTap: () => shell.open(const PayoutsScreen()),
                  ),
                  ToolRow(
                    icon: Icons.receipt_rounded,
                    color: AppColors.blue,
                    title: 'GST invoices',
                    subtitle: 'Commission invoices for each payout',
                    onTap: () => shell.open(const PayoutsScreen(invoices: true)),
                  ),
                  if (shell.type.isVenue)
                    ToolRow(
                      icon: Icons.table_chart_rounded,
                      color: AppColors.purple,
                      title: 'Monthly statement',
                      subtitle: 'Membership sales and visit payouts, month by month',
                      onTap: () => shell.open(PartnerEarningsScreen(venueId: _venueId)),
                    ),
                  if (shell.type == PartnerType.storeSeller)
                    ToolRow(
                      icon: Icons.shopping_bag_rounded,
                      color: AppColors.teal,
                      title: 'Store sales',
                      subtitle: 'Orders, marketplace commission and net sales',
                      onTap: () => shell.open(const VendorPortalScreen(initialTab: 2)),
                    ),
                  if (shell.type == PartnerType.trainer)
                    ToolRow(
                      icon: Icons.calendar_month_rounded,
                      color: AppColors.teal,
                      title: 'Session earnings',
                      subtitle: 'Paid sessions, day by day',
                      onTap: () => shell.open(const PartnerTrainerScreen(initialTab: 1)),
                    ),
                  const TabSection('Commission'),
                  Tap(onTap: () => shell.goTab(ShellTab.account), child: const CommissionPlanCard(compact: true)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.data, required this.period, required this.venueId});
  final EarningsBreakdown data;
  final EarnPeriod period;
  final String? venueId;

  @override
  Widget build(BuildContext context) {
    final shell = PartnerShell.of(context);
    final sources = [...data.bySource]..sort((a, b) => b.netPaise.compareTo(a.netPaise));
    final maxNet = sources.fold(0, (m, s) => s.netPaise > m ? s.netPaise : m);
    final (from, to) = period.range();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(gradient: AppColors.passGradient, borderRadius: BorderRadius.circular(22)),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${period.label.toUpperCase()} · NET',
                style: const TextStyle(
                  color: AppColors.lime,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                formatPaise(data.netPaise),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 38,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                ),
              ),
              Text(
                from == to ? formatShortDate(from) : '${formatShortDate(from)} – ${formatShortDate(to)}',
                style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: 12.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _Deductions(data: data),
        const TabSection('By source'),
        if (sources.isEmpty)
          const AppCard(
            child: Text(
              'No earnings in this period yet.',
              style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600),
            ),
          )
        else
          AppCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                for (final s in sources)
                  _SourceRow(
                    s: s,
                    max: maxNet,
                    onTap: s.source == 'fitkey_pass'
                        ? () => shell.open(PassVisitsScreen(venueId: venueId, initialDate: to))
                        : null,
                  ),
              ],
            ),
          ),
        if (data.byDay.length > 1) ...[
          const TabSection('Per day'),
          AppCard(
            child: SizedBox(height: 190, child: _DayChart(days: data.byDay)),
          ),
        ],
        if (sources.any((s) => s.source == 'fitkey_pass')) ...[
          const SizedBox(height: 10),
          ToolRow(
            icon: Icons.qr_code_2_rounded,
            color: AppColors.primary,
            title: 'FitKey pass visits',
            subtitle: 'Each check-in with its payout and commission',
            onTap: () => shell.open(PassVisitsScreen(venueId: venueId, initialDate: to)),
          ),
        ],
      ],
    );
  }
}

class _Deductions extends StatelessWidget {
  const _Deductions({required this.data});
  final EarningsBreakdown data;

  @override
  Widget build(BuildContext context) {
    Widget row(String label, int paise, {Color color = AppColors.text, bool bold = false, String? note}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontSize: bold ? 15 : 14),
                ),
                if (note != null) Text(note, style: const TextStyle(color: AppColors.text3, fontSize: 11.5)),
              ],
            ),
          ),
          Text(
            formatPaise(paise),
            style: TextStyle(
              fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
              color: color,
              fontSize: bold ? 16 : 14,
            ),
          ),
        ],
      ),
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('How your earnings add up', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
          const SizedBox(height: 8),
          row('Gross', data.grossPaise),
          row(
            'FitKey commission',
            -data.commissionPaise,
            color: AppColors.red,
            note: 'As per your plan year: 0% → 2.5% → 5%',
          ),
          row(
            'GST',
            -data.gstPaise,
            color: AppColors.red,
            note: 'Only on plans sold through FitKey. FitKey bears GST on pass visits.',
          ),
          const Divider(height: 18, color: AppColors.line),
          row('You get', data.netPaise, color: AppColors.green, bold: true),
          const SizedBox(height: 4),
          const Text(
            'Self, Fitpass and other sources are your own records — no commission is taken on them.',
            style: TextStyle(color: AppColors.text3, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.s, required this.max, this.onTap});
  final SourceAmount s;
  final int max;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = earningSourceColor(s.source);
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          IconBubble(earningSourceIcon(s.source), color: c, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(s.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                    Text(formatPaise(s.netPaise), style: const TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: max <= 0 ? 0 : (s.netPaise / max).clamp(0, 1).toDouble(),
                    minHeight: 6,
                    color: c,
                    backgroundColor: AppColors.surfaceAlt,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (s.count > 0)
                      '${s.count} ${s.source == 'fitkey_pass' ? 'visit' : 'sale'}${s.count == 1 ? '' : 's'}',
                    if (s.commissionPaise > 0) 'commission ${formatPaise(s.commissionPaise)}',
                    if (s.gstPaise > 0) 'GST ${formatPaise(s.gstPaise)}',
                  ].join(' · '),
                  style: const TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          if (onTap != null) const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

class _DayChart extends StatelessWidget {
  const _DayChart({required this.days});
  final List<DayAmount> days;

  @override
  Widget build(BuildContext context) {
    final maxY = days.fold(0, (m, d) => d.netPaise > m ? d.netPaise : m) / 100;
    final step = (days.length / 6).ceil().clamp(1, 31);
    return BarChart(
      BarChartData(
        maxY: maxY <= 0 ? 1 : maxY * 1.15,
        alignment: BarChartAlignment.spaceAround,
        borderData: FlBorderData(show: false),
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => const FlLine(color: AppColors.line, strokeWidth: 1),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => AppColors.ink,
            getTooltipItem: (g, _, rod, _) => BarTooltipItem(
              '${days[g.x].date == null ? '' : DateFormat('d MMM').format(days[g.x].date!)}\n${formatPaise((rod.toY * 100).round())}',
              const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (v, meta) => v == meta.max
                  ? const SizedBox.shrink()
                  : Text(
                      compactRupees((v * 100).round()),
                      style: const TextStyle(fontSize: 10, color: AppColors.text3),
                    ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i % step != 0 || i >= days.length || days[i].date == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    DateFormat('d/M').format(days[i].date!),
                    style: const TextStyle(fontSize: 10, color: AppColors.text3),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < days.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: days[i].netPaise / 100,
                  width: days.length > 20 ? 6 : 12,
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(3),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
