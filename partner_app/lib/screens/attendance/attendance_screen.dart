import 'dart:math' as math;

import 'package:fitkey_core/fitkey_core.dart' show apiDate, formatClock, formatDayDate, formatShortDate;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';

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
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Attendance'),
            Text(venueName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600)),
          ]),
          bottom: const TabBar(tabs: [Tab(text: 'Daily'), Tab(text: 'Monthly')]),
        ),
        body: TabBarView(children: [_DailyTab(venueId: venueId), _MonthlyTab(venueId: venueId)]),
      ),
    );
  }
}

/// ‹ label › switcher used by both tabs.
class _PeriodSwitcher extends StatelessWidget {
  const _PeriodSwitcher({required this.label, required this.onPrev, required this.onNext, this.onTapLabel, this.icon});

  final String label;
  final VoidCallback onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onTapLabel;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    Widget arrow(IconData i, VoidCallback? f) => IconButton(
          onPressed: f,
          icon: Icon(i),
          color: AppColors.text,
          disabledColor: AppColors.line,
          style: IconButton.styleFrom(backgroundColor: AppColors.surfaceAlt),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: AppCard(
        padding: const EdgeInsets.all(6),
        radius: 16,
        child: Row(children: [
          arrow(Icons.chevron_left_rounded, onPrev),
          Expanded(
            child: Tap(
              onTap: onTapLabel,
              scale: 0.98,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (icon != null) ...[Icon(icon, size: 18, color: AppColors.primary), const SizedBox(width: 8)],
                  Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                  ),
                ]),
              ),
            ),
          ),
          arrow(Icons.chevron_right_rounded, onNext),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Daily
// ---------------------------------------------------------------------------

class _DailyTab extends StatefulWidget {
  const _DailyTab({required this.venueId});

  final String venueId;

  @override
  State<_DailyTab> createState() => _DailyTabState();
}

class _DailyTabState extends State<_DailyTab> with AutomaticKeepAliveClientMixin {
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  late Future<List<AttendanceEntry>> _future = _load();

  @override
  bool get wantKeepAlive => true;

  Future<List<AttendanceEntry>> _load() =>
      context.read<PartnerSession>().api.attendance(widget.venueId, date: apiDate(_date));

  void _setDate(DateTime d) => setState(() {
        _date = DateUtils.dateOnly(d);
        _future = _load();
      });

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // Shown by the error state.
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (d != null && mounted) _setDate(d);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isToday = DateUtils.isSameDay(_date, DateTime.now());
    return Column(children: [
      _PeriodSwitcher(
        icon: Icons.calendar_today_rounded,
        label: isToday ? 'Today · ${formatShortDate(_date)}' : formatDayDate(_date),
        onPrev: () => _setDate(_date.subtract(const Duration(days: 1))),
        onNext: isToday ? null : () => _setDate(_date.add(const Duration(days: 1))),
        onTapLabel: _pickDate,
      ),
      Expanded(
        child: FutureBuilder<List<AttendanceEntry>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SkeletonList(count: 5, itemHeight: 52);
            }
            return RefreshIndicator(
              onRefresh: _refresh,
              child: snap.hasError
                  ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
                      const SizedBox(height: 40),
                      ErrorView(error: snap.error!, onRetry: _refresh),
                    ])
                  : _list(snap.data!, isToday),
            );
          },
        ),
      ),
    ]);
  }

  Widget _list(List<AttendanceEntry> list, bool isToday) {
    final qr = list.where((c) => c.method == 'qr').length;
    final otp = list.where((c) => c.method == 'otp').length;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
      children: [
        Row(children: [
          Expanded(
            child: MetricTile(label: 'Members checked in', value: '${list.length}', icon: Icons.how_to_reg_rounded),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: MetricTile(
              label: 'Via QR / OTP',
              value: '$qr / $otp',
              icon: Icons.qr_code_2_rounded,
              color: AppColors.blue,
            ),
          ),
        ]),
        if (list.isEmpty)
          EmptyView(
            icon: Icons.event_busy_rounded,
            title: isToday ? 'No check-ins yet today' : 'No check-ins on this day',
            message: isToday
                ? 'Keep the check-in QR open at your front desk — members show up here as they scan.'
                : 'Try another date, or switch to Monthly to see the trend.',
            action: isToday
                ? null
                : SizedBox(
                    width: 180,
                    child: OutlinedButton(onPressed: _pickDate, child: const Text('Pick a date')),
                  ),
          )
        else ...[
          SectionTitle('Visitors', subtitle: 'Most recent first'),
          for (final c in list)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AppCard(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  PersonAvatar(name: c.memberName, size: 42),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.memberName ?? 'FITKEY member',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(
                        ['•••• ${c.phoneLast4 ?? '----'}', if (c.planName != null) c.planName!].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                      ),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(formatClock(c.checkedInAt), style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Tag(c.method.toUpperCase(),
                        color: c.method == 'qr' ? AppColors.primary : AppColors.blue, dense: true),
                  ]),
                ]),
              ),
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Monthly
// ---------------------------------------------------------------------------

class _MonthlyTab extends StatefulWidget {
  const _MonthlyTab({required this.venueId});

  final String venueId;

  @override
  State<_MonthlyTab> createState() => _MonthlyTabState();
}

class _MonthlyTabState extends State<_MonthlyTab> with AutomaticKeepAliveClientMixin {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  late Future<AttendanceSummary> _future = _load();

  @override
  bool get wantKeepAlive => true;

  Future<AttendanceSummary> _load() => context
      .read<PartnerSession>()
      .api
      .attendanceSummary(widget.venueId, month: DateFormat('yyyy-MM').format(_month));

  void _shift(int months) => setState(() {
        _month = DateTime(_month.year, _month.month + months);
        _future = _load();
      });

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // Shown by the error state.
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final now = DateTime.now();
    final isCurrent = _month.year == now.year && _month.month == now.month;
    return Column(children: [
      _PeriodSwitcher(
        icon: Icons.calendar_month_rounded,
        label: DateFormat('MMMM yyyy').format(_month),
        onPrev: () => _shift(-1),
        onNext: isCurrent ? null : () => _shift(1),
      ),
      Expanded(
        child: FutureBuilder<AttendanceSummary>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return Shimmer(
                child: ListView(padding: const EdgeInsets.all(16), children: const [
                  Row(children: [
                    Expanded(child: SkeletonBox(height: 110, radius: 20)),
                    SizedBox(width: 12),
                    Expanded(child: SkeletonBox(height: 110, radius: 20)),
                  ]),
                  SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: SkeletonBox(height: 110, radius: 20)),
                    SizedBox(width: 12),
                    Expanded(child: SkeletonBox(height: 110, radius: 20)),
                  ]),
                  SizedBox(height: 16),
                  SkeletonBox(height: 260, radius: 20),
                ]),
              );
            }
            return RefreshIndicator(
              onRefresh: _refresh,
              child: snap.hasError
                  ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
                      const SizedBox(height: 40),
                      ErrorView(error: snap.error!, onRetry: _refresh),
                    ])
                  : _summary(snap.data!),
            );
          },
        ),
      ),
    ]);
  }

  Widget _summary(AttendanceSummary s) {
    final activeDays = s.days.where((d) => d.count > 0).length;
    final best = s.days.isEmpty ? null : s.days.reduce((a, b) => b.count > a.count ? b : a);

    // Average check-ins per weekday (only days that have already happened count).
    final today = DateUtils.dateOnly(DateTime.now());
    final sums = List.filled(7, 0);
    final counts = List.filled(7, 0);
    for (final d in s.days) {
      if (d.date.isAfter(today)) continue;
      sums[d.date.weekday - 1] += d.count;
      counts[d.date.weekday - 1]++;
    }
    final weekdayAvg = [for (var i = 0; i < 7; i++) counts[i] == 0 ? 0.0 : sums[i] / counts[i]];
    final maxAvg = weekdayAvg.fold<double>(0, math.max);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
      children: [
        Row(children: [
          Expanded(child: MetricTile(label: 'Total check-ins', value: '${s.total}', icon: Icons.how_to_reg_rounded)),
          const SizedBox(width: 12),
          Expanded(
            child: MetricTile(
                label: 'Unique members', value: '${s.uniqueMembers}', icon: Icons.people_alt_rounded, color: AppColors.blue),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: MetricTile(
              label: 'Avg per active day',
              value: activeDays == 0 ? '0' : (s.total / activeDays).toStringAsFixed(1),
              icon: Icons.show_chart_rounded,
              color: AppColors.purple,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: MetricTile(
              label: best == null || best.count == 0 ? 'Busiest day' : 'Busiest · ${best.count} visits',
              value: best == null || best.count == 0 ? '—' : formatShortDate(best.date),
              icon: Icons.local_fire_department_rounded,
              color: AppColors.amber,
            ),
          ),
        ]),
        const SizedBox(height: 16),
        AppCard(
          padding: const EdgeInsets.fromLTRB(12, 16, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Row(children: [
                const Expanded(
                  child: Text('Check-ins per day', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                ),
                Tag('$activeDays active day${activeDays == 1 ? '' : 's'}', color: AppColors.green, dense: true),
              ]),
            ),
            const SizedBox(height: 18),
            SizedBox(height: 210, child: _MonthChart(days: s.days)),
          ]),
        ),
        if (s.total > 0) ...[
          const SectionTitle('Busiest weekdays', subtitle: 'Average check-ins per day this month'),
          AppCard(
            child: Column(children: [
              for (var i = 0; i < 7; i++)
                Padding(
                  padding: EdgeInsets.only(bottom: i == 6 ? 0 : 10),
                  child: Row(children: [
                    SizedBox(
                      width: 38,
                      child: Text(const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][i],
                          style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.text2)),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: maxAvg == 0 ? 0 : weekdayAvg[i] / maxAvg,
                          minHeight: 10,
                          color: weekdayAvg[i] == maxAvg && maxAvg > 0 ? AppColors.primary : const Color(0xFFFFB59E),
                          backgroundColor: AppColors.surfaceAlt,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(weekdayAvg[i].toStringAsFixed(1),
                          textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ]),
                ),
            ]),
          ),
        ],
      ],
    );
  }
}

const _axisStyle = TextStyle(fontSize: 10.5, color: AppColors.text3, fontWeight: FontWeight.w600);

class _MonthChart extends StatelessWidget {
  const _MonthChart({required this.days});

  final List<({DateTime date, int count})> days;

  @override
  Widget build(BuildContext context) {
    final maxCount = days.fold<int>(0, (m, d) => math.max(m, d.count));
    final maxY = math.max(4, maxCount + 1).toDouble();
    final interval = math.max(1, (maxY / 4).ceilToDouble()).toDouble();
    return BarChart(BarChartData(
      maxY: maxY,
      alignment: BarChartAlignment.spaceAround,
      gridData: FlGridData(
        drawVerticalLine: false,
        horizontalInterval: interval,
        getDrawingHorizontalLine: (_) => const FlLine(color: AppColors.line, strokeWidth: 1, dashArray: [4, 4]),
      ),
      borderData: FlBorderData(show: false),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => AppColors.ink,
          tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          getTooltipItem: (group, _, rod, _) => BarTooltipItem(
            '${formatDayDate(days[group.x].date)}\n',
            const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
            children: [
              TextSpan(
                text: '${rod.toY.toInt()} check-in${rod.toY.toInt() == 1 ? '' : 's'}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 26,
            interval: interval,
            getTitlesWidget: (v, meta) =>
                v == meta.max ? const SizedBox.shrink() : Text(v.toInt().toString(), style: _axisStyle),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            getTitlesWidget: (v, _) {
              final day = v.toInt() + 1;
              if (day != 1 && day % 5 != 0) return const SizedBox.shrink();
              return Padding(padding: const EdgeInsets.only(top: 6), child: Text('$day', style: _axisStyle));
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
              gradient: days[i].count > 0
                  ? const LinearGradient(
                      colors: [Color(0xFFFF8A5C), AppColors.primary],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    )
                  : null,
              color: days[i].count > 0 ? null : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(3),
              backDrawRodData: BackgroundBarChartRodData(show: true, toY: maxY, color: AppColors.bg),
            ),
          ]),
      ],
    ));
  }
}
