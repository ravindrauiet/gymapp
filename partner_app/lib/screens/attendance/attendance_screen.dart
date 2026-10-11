import 'dart:math' as math;

import 'package:fitkey_core/fitkey_core.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/partner_session.dart';

/// P7 — daily list of FITKEY members who checked in, plus counts by day for a month.
class AttendanceScreen extends StatelessWidget {
  const AttendanceScreen({super.key, required this.venueId, required this.venueName});

  final String venueId;
  final String venueName;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(venueName),
          bottom: const TabBar(tabs: [Tab(text: 'Daily'), Tab(text: 'Monthly')]),
        ),
        body: TabBarView(children: [_DailyTab(venueId: venueId), _MonthlyTab(venueId: venueId)]),
      ),
    );
  }
}

class _DailyTab extends StatefulWidget {
  const _DailyTab({required this.venueId});

  final String venueId;

  @override
  State<_DailyTab> createState() => _DailyTabState();
}

class _DailyTabState extends State<_DailyTab> {
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  late Future<List<AttendanceEntry>> _future = _load();

  Future<List<AttendanceEntry>> _load() =>
      context.read<PartnerSession>().api.attendance(widget.venueId, date: apiDate(_date));

  void _setDate(DateTime d) => setState(() {
        _date = d;
        _future = _load();
      });

  @override
  Widget build(BuildContext context) {
    final isToday = DateUtils.isSameDay(_date, DateTime.now());
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Row(children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _setDate(_date.subtract(const Duration(days: 1))),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2024),
                  lastDate: DateTime.now(),
                );
                if (d != null) _setDate(d);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(isToday ? 'Today · ${formatShortDate(_date)}' : formatDayDate(_date),
                    textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: isToday ? null : () => _setDate(_date.add(const Duration(days: 1))),
          ),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: () async {
            final f = _load();
            setState(() => _future = f);
            await f;
          },
          child: AsyncView<List<AttendanceEntry>>(
            future: _future,
            onRetry: () => _setDate(_date),
            builder: (context, list) => ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: [
                Row(children: [
                  Expanded(child: StatTile(label: 'Members checked in', value: '${list.length}', icon: Icons.login)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      label: 'Via QR / OTP',
                      value: '${list.where((c) => c.method == 'qr').length} / ${list.where((c) => c.method == 'otp').length}',
                      icon: Icons.qr_code_2,
                      color: FkColors.sky,
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                if (list.isEmpty)
                  const EmptyState(icon: Icons.event_busy, title: 'No check-ins on this day')
                else
                  ...list.map((c) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Avatar(name: c.memberName, radius: 20),
                          title: Text(c.memberName ?? 'FITKEY member', style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('•••• ${c.phoneLast4 ?? ''}${c.planName == null ? '' : ' · ${c.planName}'}'),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(formatClock(c.checkedInAt), style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(c.method.toUpperCase(),
                                  style: const TextStyle(fontSize: 11, color: FkColors.textSecondary)),
                            ],
                          ),
                        ),
                      )),
              ],
            ),
          ),
        ),
      ),
    ]);
  }
}

class _MonthlyTab extends StatefulWidget {
  const _MonthlyTab({required this.venueId});

  final String venueId;

  @override
  State<_MonthlyTab> createState() => _MonthlyTabState();
}

class _MonthlyTabState extends State<_MonthlyTab> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  late Future<AttendanceSummary> _future = _load();

  Future<AttendanceSummary> _load() => context
      .read<PartnerSession>()
      .api
      .attendanceSummary(widget.venueId, month: DateFormat('yyyy-MM').format(_month));

  void _shift(int months) => setState(() {
        _month = DateTime(_month.year, _month.month + months);
        _future = _load();
      });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isCurrent = _month.year == now.year && _month.month == now.month;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shift(-1)),
          Expanded(
            child: Text(DateFormat('MMMM yyyy').format(_month),
                textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ),
          IconButton(icon: const Icon(Icons.chevron_right), onPressed: isCurrent ? null : () => _shift(1)),
        ]),
      ),
      Expanded(
        child: AsyncView<AttendanceSummary>(
          future: _future,
          onRetry: () => _shift(0),
          builder: (context, s) {
            final activeDays = s.days.where((d) => d.count > 0).length;
            final best = s.days.isEmpty ? null : s.days.reduce((a, b) => b.count > a.count ? b : a);
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: [
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.7,
                  children: [
                    StatTile(label: 'Total check-ins', value: '${s.total}', icon: Icons.login),
                    StatTile(
                        label: 'Unique members', value: '${s.uniqueMembers}', icon: Icons.people_outline, color: FkColors.sky),
                    StatTile(
                        label: 'Daily average',
                        value: activeDays == 0 ? '0' : (s.total / activeDays).toStringAsFixed(1),
                        icon: Icons.show_chart,
                        color: FkColors.violet),
                    StatTile(
                      label: 'Busiest day',
                      value: best == null || best.count == 0 ? '—' : formatShortDate(best.date),
                      icon: Icons.local_fire_department,
                      color: FkColors.orange,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 16, 16, 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Text('Check-ins per day', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(height: 200, child: _MonthChart(days: s.days)),
                    ]),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ]);
  }
}

class _MonthChart extends StatelessWidget {
  const _MonthChart({required this.days});

  final List<({DateTime date, int count})> days;

  @override
  Widget build(BuildContext context) {
    final maxY = math.max(4, days.fold<int>(0, (m, d) => math.max(m, d.count))).toDouble();
    return BarChart(BarChartData(
      maxY: maxY * 1.15,
      gridData: FlGridData(
        drawVerticalLine: false,
        horizontalInterval: math.max(1, (maxY / 4).ceilToDouble()),
        getDrawingHorizontalLine: (_) => const FlLine(color: FkColors.outline, strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => FkColors.surfaceHigh,
          getTooltipItem: (group, _, rod, _) => BarTooltipItem(
            '${formatShortDate(days[group.x].date)}\n${rod.toY.toInt()} check-ins',
            const TextStyle(color: FkColors.textPrimary, fontSize: 12),
          ),
        ),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 28,
            interval: math.max(1, (maxY / 4).ceilToDouble()),
            getTitlesWidget: (v, _) =>
                Text(v.toInt().toString(), style: const TextStyle(fontSize: 10, color: FkColors.textSecondary)),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 20,
            getTitlesWidget: (v, _) {
              final day = v.toInt() + 1;
              if (day != 1 && day % 5 != 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('$day', style: const TextStyle(fontSize: 10, color: FkColors.textSecondary)),
              );
            },
          ),
        ),
      ),
      barGroups: [
        for (var i = 0; i < days.length; i++)
          BarChartGroupData(x: i, barRods: [
            BarChartRodData(
              toY: days[i].count.toDouble(),
              width: 6,
              color: days[i].count > 0 ? FkColors.lime : FkColors.surfaceHigh,
              borderRadius: BorderRadius.circular(3),
            ),
          ]),
      ],
    ));
  }
}
