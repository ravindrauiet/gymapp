import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import '../goals/goal_selection_screen.dart';
import 'attendance_screen.dart';
import 'log_sheets.dart';
import 'step_sync_sheet.dart';

/// U9 — Health / gym report: attendance, workouts, weight trend.
class HealthReportScreen extends StatefulWidget {
  const HealthReportScreen({super.key});

  @override
  State<HealthReportScreen> createState() => _HealthReportScreenState();
}

class _HealthReportScreenState extends State<HealthReportScreen> {
  int _days = 30;
  late Future<HealthReport> _future = _load();

  Future<HealthReport> _load() => context.read<Session>().api.healthReport(days: _days);

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My progress'),
        actions: [
          IconButton(
            tooltip: 'Activity log',
            icon: const Icon(Icons.list_alt),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const ActivityLogScreen()));
              _reload();
            },
          ),
        ],
      ),
      body: AsyncView<HealthReport>(
        future: _future,
        onRetry: _reload,
        builder: (context, r) => RefreshIndicator(
          onRefresh: () async {
            _reload();
            await _future;
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 7, label: Text('7 days')),
                  ButtonSegment(value: 30, label: Text('30 days')),
                  ButtonSegment(value: 90, label: Text('90 days')),
                ],
                selected: {_days},
                onSelectionChanged: (s) {
                  _days = s.first;
                  _reload();
                },
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.add, color: FkColors.lime),
                    label: const Text('Log workout'),
                    onPressed: () async {
                      if (await showActivitySheet(context)) _reload();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.monitor_weight_outlined, color: FkColors.sky),
                    label: const Text('Log weight'),
                    onPressed: () async {
                      if (await showWeightSheet(context, current: r.latestWeight?.weightKg)) _reload();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.directions_walk, color: FkColors.orange),
                    label: const Text('Sync steps'),
                    onPressed: () async {
                      final updated = await showModalBottomSheet<bool>(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) => const StepSyncSheet(),
                      );
                      if (updated == true) _reload();
                    },
                  ),
                ),
              ]),
              const SizedBox(height: 16),

              // 5. Central Integration Architecture (Gym & Health Report Engine)
              Card(
                color: const Color(0xFF1B2028),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: FkColors.lime.withValues(alpha: 0.3)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.hub, color: FkColors.lime, size: 22),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Central Gym & Health Report Engine',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Colors.white),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const GoalSelectionScreen(isEditing: true)),
                          );
                          _reload();
                        },
                        child: const Text('Edit Goal', style: TextStyle(color: FkColors.lime, fontSize: 12)),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    const Text(
                      'Cross-functional integration combining your Onboarding Profile, Activity Engine, Attendance QR Logs, and Fuel Nutrition tracker.',
                      style: TextStyle(color: FkColors.textSecondary, fontSize: 12, height: 1.3),
                    ),
                    const Divider(height: 20),
                    ...r.integrationRows.map((row) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(color: FkColors.lime, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 8),
                              Text(row.source, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                              const Spacer(),
                              Text(row.metric,
                                  style: const TextStyle(color: FkColors.textSecondary, fontSize: 11)),
                            ]),
                            Padding(
                              padding: const EdgeInsets.only(left: 16, top: 2),
                              child: Text(row.outcome,
                                  style: const TextStyle(
                                      color: FkColors.lime, fontWeight: FontWeight.w600, fontSize: 12)),
                            ),
                          ]),
                        )),
                  ]),
                ),
              ),

              // Activity & Movement Engine
              if (r.movement != null) ...[
                const SectionHeader('Activity & Movement Engine'),
                Row(children: [
                  Expanded(
                    child: StatTile(
                      label: 'Avg Daily Steps',
                      value: r.movement!.avgDailySteps.toString(),
                      icon: Icons.directions_walk,
                      color: FkColors.lime,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      label: 'Distance (KM)',
                      value: formatNumber(r.movement!.totalDistanceKm),
                      icon: Icons.route,
                      color: FkColors.sky,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      label: 'Movement Score',
                      value: '${r.movement!.movementScore}/100',
                      icon: Icons.speed,
                      color: FkColors.orange,
                    ),
                  ),
                ]),
              ],

              // Fuel Log (Nutrition Integration)
              if (r.nutrition != null) ...[
                const SectionHeader('Fuel Log (Nutrition Progress)'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('Daily Average Intake', style: TextStyle(color: FkColors.textSecondary, fontSize: 12)),
                            const SizedBox(height: 2),
                            Text('${r.nutrition!.avgDailyCalories} kcal',
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: FkColors.lime)),
                          ]),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: FkColors.lime.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            r.nutrition!.deficitSurplusStatus,
                            style: const TextStyle(color: FkColors.lime, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                          child: Text(
                            'Daily Baseline Benchmark: ${r.nutrition!.dailyCalorieBaseline} kcal · ${r.nutrition!.dailyProteinBaseline}g protein',
                            style: const TextStyle(color: FkColors.textSecondary, fontSize: 12),
                          ),
                        ),
                      ]),
                      const Divider(height: 20),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                        _nutriTile('Protein', '${r.nutrition!.avgDailyProtein}g', FkColors.sky),
                        _nutriTile('Carbs', '${r.nutrition!.avgDailyCarbs}g', FkColors.orange),
                        _nutriTile('Fats', '${r.nutrition!.avgDailyFat}g', FkColors.violet),
                      ]),
                    ]),
                  ),
                ),
              ],
              const SectionHeader('Attendance'),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.7,
                children: [
                  StatTile(label: 'Check-ins', value: '${r.totalCheckins}', icon: Icons.login),
                  StatTile(
                      label: 'Current streak',
                      value: '${r.currentStreak} days',
                      icon: Icons.local_fire_department,
                      color: FkColors.orange),
                  StatTile(label: 'Active days', value: '${r.activeDays}', icon: Icons.calendar_month, color: FkColors.sky),
                  StatTile(label: 'Venues visited', value: '${r.uniqueVenues}', icon: Icons.place, color: FkColors.violet),
                ],
              ),
              const SizedBox(height: 12),
              _ChartCard(title: 'Check-ins per day', child: _CheckinChart(report: r)),
              if (r.topVenues.isNotEmpty) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Favourite venues', style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      ...r.topVenues.map((v) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(children: [
                              Expanded(child: Text(v.name)),
                              Text('${v.visits} visits', style: const TextStyle(color: FkColors.textSecondary)),
                            ]),
                          )),
                    ]),
                  ),
                ),
              ],
              TextButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AttendanceScreen())),
                child: const Text('See full attendance history', style: TextStyle(color: FkColors.lime)),
              ),
              const SectionHeader('Workouts'),
              Row(children: [
                Expanded(child: StatTile(label: 'Sessions', value: '${r.workoutCount}', icon: Icons.bolt)),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                      label: 'Minutes', value: '${r.totalMinutes}', icon: Icons.timer_outlined, color: FkColors.sky),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                      label: 'Km', value: formatNumber(r.totalDistanceKm), icon: Icons.route, color: FkColors.orange),
                ),
              ]),
              if (r.workoutsByType.isNotEmpty) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: r.workoutsByType.map((t) {
                        final style = activityType(t.type);
                        final maxCount = r.workoutsByType.map((e) => e.count).reduce(math.max);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            Icon(style.icon, color: style.color, size: 20),
                            const SizedBox(width: 10),
                            SizedBox(width: 80, child: Text(style.label)),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  value: t.count / maxCount,
                                  minHeight: 8,
                                  color: style.color,
                                  backgroundColor: FkColors.surfaceHigh,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text('${t.count}×', style: const TextStyle(fontWeight: FontWeight.w700)),
                          ]),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
              const SectionHeader('Weight'),
              Row(children: [
                Expanded(
                  child: StatTile(
                    label: 'Latest',
                    value: r.latestWeight == null ? '--' : '${formatNumber(r.latestWeight!.weightKg)} kg',
                    icon: Icons.monitor_weight_outlined,
                    color: FkColors.sky,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'Change ($_days days)',
                    value: r.weightChangeKg == null
                        ? '--'
                        : '${r.weightChangeKg! > 0 ? '+' : ''}${formatNumber(r.weightChangeKg!)} kg',
                    icon: (r.weightChangeKg ?? 0) <= 0 ? Icons.trending_down : Icons.trending_up,
                    color: FkColors.violet,
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              _ChartCard(
                title: 'Weight trend',
                child: r.weightSeries.length < 2
                    ? const Center(
                        child: Text('Log your weight on 2+ days to see a trend',
                            style: TextStyle(color: FkColors.textSecondary)),
                      )
                    : _WeightChart(points: r.weightSeries),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          SizedBox(height: 160, child: child),
        ]),
      ),
    );
  }
}

class _CheckinChart extends StatelessWidget {
  const _CheckinChart({required this.report});

  final HealthReport report;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final days = List.generate(report.days, (i) => today.subtract(Duration(days: report.days - 1 - i)));
    final counts = days.map((d) => report.checkinsPerDay[d] ?? 0).toList();
    final maxY = math.max(2, counts.fold<int>(0, math.max)).toDouble();
    final labelEvery = math.max(1, report.days ~/ 6);

    return BarChart(BarChartData(
      maxY: maxY,
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      barTouchData: BarTouchData(enabled: false),
      titlesData: FlTitlesData(
        leftTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        topTitles: const AxisTitles(),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            getTitlesWidget: (value, meta) {
              final i = value.toInt();
              if (i % labelEvery != 0 && i != days.length - 1) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(formatShortDate(days[i]), style: const TextStyle(fontSize: 9, color: FkColors.textSecondary)),
              );
            },
          ),
        ),
      ),
      barGroups: [
        for (var i = 0; i < counts.length; i++)
          BarChartGroupData(x: i, barRods: [
            BarChartRodData(
              toY: counts[i].toDouble(),
              width: report.days > 30 ? 2.5 : (report.days > 7 ? 5 : 16),
              color: counts[i] > 0 ? FkColors.lime : FkColors.surfaceHigh,
              borderRadius: BorderRadius.circular(3),
              backDrawRodData: BackgroundBarChartRodData(show: true, toY: maxY, color: FkColors.surfaceHigh),
            ),
          ]),
      ],
    ));
  }
}

class _WeightChart extends StatelessWidget {
  const _WeightChart({required this.points});

  final List<WeightPoint> points;

  @override
  Widget build(BuildContext context) {
    final first = points.first.loggedOn;
    final spots = points.map((p) => FlSpot(p.loggedOn.difference(first).inDays.toDouble(), p.weightKg)).toList();
    final weights = points.map((p) => p.weightKg);
    final minY = (weights.reduce(math.min) - 1).floorToDouble();
    final maxY = (weights.reduce(math.max) + 1).ceilToDouble();

    return LineChart(LineChartData(
      minY: minY,
      maxY: maxY,
      gridData: FlGridData(
        drawVerticalLine: false,
        getDrawingHorizontalLine: (_) => const FlLine(color: FkColors.outline, strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        rightTitles: const AxisTitles(),
        topTitles: const AxisTitles(),
        bottomTitles: const AxisTitles(),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 32,
            getTitlesWidget: (v, meta) =>
                Text(v.toStringAsFixed(0), style: const TextStyle(fontSize: 10, color: FkColors.textSecondary)),
          ),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          preventCurveOverShooting: true,
          color: FkColors.sky,
          barWidth: 3,
          dotData: FlDotData(show: spots.length < 15),
          belowBarData: BarAreaData(show: true, color: FkColors.sky.withValues(alpha: 0.12)),
        ),
      ],
    ));
  }
}

Widget _nutriTile(String label, String value, Color color) {
  return Column(children: [
    Text(label, style: const TextStyle(color: FkColors.textSecondary, fontSize: 11)),
    const SizedBox(height: 2),
    Text(value, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: color)),
  ]);
}
