import 'dart:math' as math;

import 'package:fitkey_core/fitkey_core.dart' show formatNumber, formatShortDate;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/progress_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../goals/goal_selection_screen.dart';
import '../nutrition/fuel_log_screen.dart';
import 'attendance_screen.dart';
import 'health_sync.dart';
import 'log_sheets.dart';
import 'step_sync_sheet.dart';

final _grouped = NumberFormat.decimalPattern('en_IN');
String _n(num v) => v % 1 == 0 ? _grouped.format(v.round()) : formatNumber(v);

/// U9 / BRD §4 — Progress: a goal-based report in three tabs (Overview | Workout | Nutrition).
///
/// [initialTab] is 'overview', 'workout' or 'nutrition'. When omitted the tab is picked by usage:
/// Fuel Log only → Nutrition, gym only → Workout, both → Overview.
class HealthReportScreen extends StatefulWidget {
  const HealthReportScreen({super.key, this.initialTab});

  final String? initialTab;

  @override
  State<HealthReportScreen> createState() => _HealthReportScreenState();
}

const _tabKeys = ['overview', 'workout', 'nutrition'];

class _HealthReportScreenState extends State<HealthReportScreen> with SingleTickerProviderStateMixin {
  static const _periods = [7, 30, 90];
  int _days = 7;
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: math.max(0, _tabKeys.indexOf(widget.initialTab ?? 'overview')),
  );

  ProgressReport? _report;
  Object? _error;
  bool _loading = true;
  int _req = 0;
  bool _appliedDefaultTab = false;
  bool _autoSynced = false;
  int? _waterToday;
  bool _waterBusy = false;
  bool _repeatBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = ++_req;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<Session>().api.progressReport(days: _days);
      if (!mounted || id != _req) return;
      setState(() {
        _report = r;
        _waterToday = null;
        _loading = false;
      });
      if (!_appliedDefaultTab) {
        _appliedDefaultTab = true;
        final idx = _tabKeys.indexOf(r.defaultTab);
        if (widget.initialTab == null && idx > 0 && _tabs.index == 0) _tabs.animateTo(idx);
      }
      if (!_autoSynced) {
        _autoSynced = true;
        _autoSyncHealth(r);
      }
    } catch (e) {
      if (!mounted || id != _req) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Health Connect / HealthKit already connected → quietly back-fill the last week, then refresh.
  Future<void> _autoSyncHealth(ProgressReport r) async {
    final sync = HealthSync.instance;
    if (!sync.isSupported) return;
    final api = context.read<Session>().api;
    try {
      final st = await sync.state();
      final connected = st == HealthSyncState.connected || (st == HealthSyncState.needsPermission && r.lastDeviceSource == sync.source);
      if (!connected) return;
      final saved = await sync.syncRecent(api, days: 7);
      if (saved > 0 && mounted) _load();
    } catch (_) {
      // Auto-sync is best effort; manual entry stays available.
    }
  }

  Future<void> _refresh() => _load();

  Future<void> _logActivity() async {
    if (await showActivitySheet(context)) {
      if (!mounted) return;
      toast(context, 'Activity logged');
      _load();
    }
  }

  Future<void> _repeatLast() async {
    setState(() => _repeatBusy = true);
    try {
      final a = await context.read<Session>().api.repeatLastActivity();
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      toast(context, '${activityVisual(a.type).label} logged again${a.calories != null ? ' · ${a.calories} kcal' : ''}');
      _load();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _repeatBusy = false);
    }
  }

  Future<void> _logWeight(double? current) async {
    if (await showWeightSheet(context, current: current)) {
      if (!mounted) return;
      toast(context, 'Weight saved');
      _load();
    }
  }

  Future<void> _syncSteps() async {
    final goal = _report?.goals.dailyStepsTarget ?? 8000;
    final updated = await showAppSheet<bool>(context, builder: (_) => StepSyncSheet(goal: goal > 0 ? goal : 8000));
    if (updated == true && mounted) _load();
  }

  Future<void> _water(int delta) async {
    if (_waterBusy) return;
    final r = _report;
    if (r == null) return;
    final current = _waterToday ?? r.water.today;
    if (current + delta < 0) return;
    setState(() {
      _waterBusy = true;
      _waterToday = current + delta;
    });
    try {
      final w = await context.read<Session>().api.addWater(delta);
      if (!mounted) return;
      HapticFeedback.selectionClick();
      setState(() => _waterToday = w.glasses);
    } catch (e) {
      if (!mounted) return;
      setState(() => _waterToday = current);
      toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _waterBusy = false);
    }
  }

  Future<void> _open(Widget screen) async {
    await push(context, screen);
    if (mounted) _load();
  }

  void _editGoal() => _open(const GoalSelectionScreen(isEditing: true));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My progress'),
        actions: [
          IconButton(
            tooltip: 'Edit goals',
            icon: const Icon(Icons.flag_rounded),
            onPressed: _editGoal,
          ),
          IconButton(
            tooltip: 'Activity log',
            icon: const Icon(Icons.history_rounded),
            onPressed: () => _open(const ActivityLogScreen()),
          ),
          const SizedBox(width: 4),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.text2,
          indicatorColor: AppColors.primary,
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          tabs: const [Tab(text: 'Overview'), Tab(text: 'Workout'), Tab(text: 'Nutrition')],
        ),
      ),
      body: Column(children: [
        Container(
          color: AppColors.surface,
          padding: const EdgeInsets.only(bottom: 12, top: 12),
          child: ChoiceChips<int>(
            options: _periods,
            selected: _days,
            label: (d) => 'Last $d days',
            icon: (d) => d == _days ? Icons.calendar_today_rounded : null,
            onSelected: (d) {
              if (d == _days) return;
              _days = d;
              _load();
            },
          ),
        ),
        Expanded(child: _body()),
      ]),
    );
  }

  Widget _body() {
    final r = _report;
    if (r == null) {
      if (_error != null) return ErrorView(error: _error!, onRetry: _load);
      return const _ReportSkeleton();
    }
    if (_loading && r.days != _days) return const _ReportSkeleton();
    Widget wrap(List<Widget> children) => RefreshIndicator(
          color: AppColors.primary,
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
            children: children,
          ),
        );
    return TabBarView(controller: _tabs, children: [
      wrap(_overview(r)),
      wrap(_workout(r)),
      wrap(_nutrition(r)),
    ]);
  }

  // ---- Overview -------------------------------------------------------------

  List<Widget> _overview(ProgressReport r) {
    GoalRing? ring(String k) => r.rings.where((g) => g.key == k).firstOrNull;
    final rings = [for (final k in ['workout_days', 'steps', 'calories', 'protein']) ?ring(k)];
    final workoutRings = rings.where((g) => g.key == 'workout_days' || g.key == 'steps');
    final nutritionRings = rings.where((g) => g.key == 'calories' || g.key == 'protein');
    String summary(Iterable<GoalRing> rs) {
      final withData = rs.where((g) => g.hasData).toList();
      if (withData.isEmpty) return 'Nothing logged yet';
      final behind = withData.where((g) => g.status == 'behind').length;
      return behind == 0 ? 'On track with ${withData.length == 1 ? 'your goal' : 'both goals'}' : '$behind of ${withData.length} goals behind';
    }

    return [
      _WeekCard(
        title: r.days == 7 ? 'This week' : 'Last ${r.days} days',
        score: r.score,
        insight: r.insight,
      ),
      if (!r.goals.hasGoal) ...[
        const SizedBox(height: 12),
        _NudgeCard(
          image: AppImages.running,
          title: 'Set your goal',
          message: 'You are seeing default targets. Add your body stats for targets made for you.',
          cta: 'Set goal',
          onTap: _editGoal,
        ),
      ],
      SectionTitle('Your goals', subtitle: 'Average over the last ${r.days} days', action: 'Edit', onAction: _editGoal),
      _Grid(children: [
        for (final g in rings)
          _GoalRingTile(
            ring: g,
            onTap: () => _tabs.animateTo(g.key == 'workout_days' || g.key == 'steps' ? 1 : 2),
          ),
      ]),
      const SizedBox(height: 16),
      _TabLinkCard(
        image: AppImages.strength,
        title: 'Workout',
        subtitle: '${summary(workoutRings)} · ${r.base.totalCheckins} check-ins · ${_n(r.burned.total)} kcal burned',
        color: AppColors.primary,
        onTap: () => _tabs.animateTo(1),
      ),
      const SizedBox(height: 12),
      _TabLinkCard(
        image: AppImages.foodBowl,
        title: 'Nutrition',
        subtitle: '${summary(nutritionRings)} · ${r.base.nutrition?.mealDays ?? 0} days logged in Fuel Log',
        color: AppColors.green,
        onTap: () => _tabs.animateTo(2),
      ),
    ];
  }

  // ---- Workout --------------------------------------------------------------

  List<Widget> _workout(ProgressReport r) {
    final b = r.base;
    final m = b.movement;
    final last = r.lastActivity;
    final stepTarget = r.goals.dailyStepsTarget;
    final stepRing = r.rings.where((g) => g.key == 'steps').firstOrNull;
    final daysRing = r.rings.where((g) => g.key == 'workout_days').firstOrNull;
    return [
      Row(children: [
        Expanded(
          child: _ScoreCard(
            score: b.gymConsistencyScore,
            title: 'Gym consistency',
            caption: '${b.totalCheckins} check-ins · ${b.currentStreak}-day streak',
            color: AppColors.primary,
            icon: Icons.local_fire_department_rounded,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ScoreCard(
            score: m?.movementScore ?? 0,
            title: 'Movement',
            caption: m == null || m.avgDailySteps == 0
                ? 'Sync steps to get scored'
                : '${_n(m.avgDailySteps)} / ${_n(stepTarget)} steps a day',
            color: AppColors.blue,
            icon: Icons.directions_walk_rounded,
          ),
        ),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(
          child: _QuickAction(
              icon: Icons.add_task_rounded, label: 'Log activity', color: AppColors.primary, onTap: _logActivity),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _QuickAction(
            icon: Icons.replay_rounded,
            label: last == null ? 'Repeat last' : 'Repeat ${activityVisual(last.type).label.toLowerCase()}',
            color: AppColors.purple,
            busy: _repeatBusy,
            onTap: last == null ? _logActivity : _repeatLast,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _QuickAction(
              icon: Icons.directions_walk_rounded, label: 'Steps', color: AppColors.amber, onTap: _syncSteps),
        ),
      ]),
      if (last != null) ...[
        const SizedBox(height: 8),
        Text(
          'Last: ${activityVisual(last.type).label}${last.durationMin != null ? ' · ${last.durationMin} min' : ''}'
          '${last.distanceKm != null ? ' · ${formatNumber(last.distanceKm!)} km' : ''} — one tap logs it again',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],

      // ---- Attendance ----
      SectionTitle('Attendance',
          subtitle: daysRing == null
              ? 'Your gym visits in the last ${r.days} days'
              : '${formatNumber(daysRing.value)} of ${daysRing.target.round()} workout days a week',
          action: 'History',
          onAction: () => push(context, const AttendanceScreen())),
      _Grid(children: [
        MetricTile(label: 'Check-ins', value: '${b.totalCheckins}', icon: Icons.login_rounded, color: AppColors.green),
        MetricTile(
            label: 'Current streak',
            value: '${b.currentStreak}',
            unit: b.currentStreak == 1 ? 'day' : 'days',
            icon: Icons.local_fire_department_rounded,
            color: AppColors.primary),
        MetricTile(label: 'Workout days', value: '${r.workoutDays}', icon: Icons.calendar_month_rounded, color: AppColors.blue),
        MetricTile(label: 'Venues visited', value: '${b.uniqueVenues}', icon: Icons.place_rounded, color: AppColors.purple),
      ]),
      const SizedBox(height: 12),
      _ChartCard(
        title: b.days > 30 ? 'Check-ins per week' : 'Check-ins per day',
        trailing: Tag('${b.totalCheckins} total', color: AppColors.primary, dense: true),
        child: b.totalCheckins == 0
            ? const _ChartEmpty(icon: Icons.qr_code_scanner_rounded, text: 'Check in at a venue to fill this chart')
            : _CheckinChart(report: b),
      ),
      if (b.topVenues.isNotEmpty) ...[
        const SizedBox(height: 12),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Favourite venues', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 6),
            for (var i = 0; i < b.topVenues.length; i++)
              _TopVenueRow(
                rank: i + 1,
                name: b.topVenues[i].name,
                visits: b.topVenues[i].visits,
                max: b.topVenues.first.visits,
              ),
          ]),
        ),
      ],

      // ---- Steps ----
      SectionTitle('Steps',
          subtitle: r.lastDeviceSource == null
              ? 'Goal ${_n(stepTarget)} a day'
              : 'Synced from ${r.lastDeviceSource == 'apple_healthkit' ? 'Apple Health' : 'Health Connect'} · goal ${_n(stepTarget)}',
          action: 'Sync',
          onAction: _syncSteps),
      if (m == null || m.totalSteps == 0)
        _NudgeCard(
          image: AppImages.running,
          title: HealthSync.instance.isSupported ? 'Connect your steps' : 'Track your daily steps',
          message: HealthSync.instance.isSupported
              ? 'Allow ${HealthSync.instance.providerName} once and your steps sync automatically.'
              : 'Add today\'s step count — auto-sync is available in the mobile app.',
          cta: HealthSync.instance.isSupported ? 'Connect' : 'Add steps',
          onTap: _syncSteps,
        )
      else ...[
        Row(children: [
          Expanded(
            child: MetricTile(
                label: 'Avg steps / day', value: _n(m.avgDailySteps), icon: Icons.directions_walk_rounded, color: AppColors.amber),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: MetricTile(
                label: 'Distance', value: formatNumber(m.totalDistanceKm), unit: 'km', icon: Icons.route_rounded, color: AppColors.teal),
          ),
        ]),
        const SizedBox(height: 12),
        _ChartCard(
          title: 'Steps vs goal',
          trailing: stepRing == null ? null : _StatusTag(stepRing.status),
          child: _TrendBars(
            points: [for (final d in r.movementSeries) (d.date, d.steps.toDouble())],
            target: stepTarget.toDouble(),
            color: AppColors.amber,
            unit: 'steps',
          ),
        ),
      ],

      // ---- Calories burned ----
      SectionTitle('Calories burned', subtitle: 'Estimated with MET × your weight, or measured by your phone / watch'),
      _BurnCard(burned: r.burned, days: r.days),

      // ---- Workouts ----
      SectionTitle('Workouts', subtitle: 'Sessions you logged', action: 'Log', onAction: _logActivity),
      _Grid(children: [
        MetricTile(label: 'Sessions', value: '${b.workoutCount}', icon: Icons.bolt_rounded, color: AppColors.primary),
        MetricTile(label: 'Minutes', value: _n(b.totalMinutes), icon: Icons.timer_rounded, color: AppColors.purple),
        MetricTile(
            label: 'Distance', value: formatNumber(b.totalDistanceKm), unit: 'km', icon: Icons.route_rounded, color: AppColors.teal),
        MetricTile(
            label: 'Calories', value: _n(b.totalCalories), unit: 'kcal', icon: Icons.local_fire_department_rounded, color: AppColors.red),
      ]),
      const SizedBox(height: 12),
      if (b.workoutsByType.isEmpty)
        _NudgeCard(
          image: AppImages.strength,
          title: 'No workouts logged yet',
          message: 'Log a workout, run or yoga session — calories are estimated for you.',
          cta: 'Log activity',
          onTap: _logActivity,
        )
      else
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('By activity', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
              Tap(
                onTap: () => _open(const ActivityLogScreen()),
                child: const Text('See log',
                    style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 13)),
              ),
            ]),
            const SizedBox(height: 8),
            for (final t in b.workoutsByType)
              _TypeRow(
                type: t.type,
                count: t.count,
                minutes: t.minutes,
                max: b.workoutsByType.map((e) => e.count).reduce(math.max),
              ),
          ]),
        ),
    ];
  }

  // ---- Nutrition ------------------------------------------------------------

  List<Widget> _nutrition(ProgressReport r) {
    final b = r.base;
    final n = b.nutrition;
    final g = r.goals;
    final calRing = r.rings.where((x) => x.key == 'calories').firstOrNull;
    final hasMeals = n != null && n.mealDays > 0;
    final water = _waterToday ?? r.water.today;
    return [
      if (!hasMeals)
        _NudgeCard(
          image: AppImages.foodBowl,
          title: 'Log your meals',
          message: 'Track what you eat in Fuel Log to see calories and macros against your goal.',
          cta: 'Open Fuel Log',
          onTap: () => _open(const FuelLogScreen()),
        )
      else ...[
        _ChartCard(
          title: 'Calories vs target',
          trailing: calRing == null ? null : _StatusTag(calRing.status),
          child: _TrendBars(
            points: [for (final d in r.nutritionSeries) (d.date, d.calories.toDouble())],
            target: g.calories.toDouble(),
            color: AppColors.primary,
            unit: 'kcal',
            highlightAtTarget: false,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Avg ${_n(n.avgDailyCalories)} kcal / day vs ${_n(g.calories)} target · ${r.daysOnCalorieTarget} of ${n.mealDays} days within 10%',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
        SectionTitle('Macros',
            subtitle: g.targetsSource == 'custom' ? 'Daily average vs your custom targets' : 'Daily average vs your targets',
            action: 'Edit targets',
            onAction: _editGoal),
        AppCard(
          child: Column(children: [
            _MacroRow('Protein', n.avgDailyProtein, g.proteinG, AppColors.purple),
            const SizedBox(height: 14),
            _MacroRow('Carbs', n.avgDailyCarbs, g.carbsG, AppColors.amber),
            const SizedBox(height: 14),
            _MacroRow('Fat', n.avgDailyFat, g.fatG, AppColors.pink),
            const SizedBox(height: 12),
            Text('Protein goal hit on ${r.daysHitProtein} of ${n.mealDays} logged days',
                style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
      ],

      // ---- Water ----
      SectionTitle('Water', subtitle: 'Goal ${r.water.target} glasses a day'),
      _WaterCard(
        today: water,
        target: r.water.target,
        avg: r.water.avgGlasses,
        daysHit: r.water.daysHit,
        loggedDays: r.water.loggedDays,
        busy: _waterBusy,
        onAdd: () => _water(1),
        onRemove: water > 0 ? () => _water(-1) : null,
      ),

      // ---- Meal consistency ----
      SectionTitle('Meal consistency', subtitle: 'How regularly you log in Fuel Log',
          action: 'Fuel Log', onAction: () => _open(const FuelLogScreen())),
      _Grid(children: [
        MetricTile(
            label: 'Days logged',
            value: '${n?.mealDays ?? 0}',
            unit: '/ ${r.days}',
            icon: Icons.event_available_rounded,
            color: AppColors.green),
        MetricTile(
            label: 'Meals a day',
            value: formatNumber(r.avgMealsPerDay),
            icon: Icons.restaurant_rounded,
            color: AppColors.amber),
        MetricTile(
            label: 'Breakfast days', value: '${r.breakfastDays}', icon: Icons.free_breakfast_rounded, color: AppColors.primary),
        MetricTile(
            label: 'Consistency',
            value: '${r.days == 0 ? 0 : (((n?.mealDays ?? 0) / r.days) * 100).round()}',
            unit: '%',
            icon: Icons.insights_rounded,
            color: AppColors.blue),
      ]),

      // ---- Weight & BMI ----
      SectionTitle('Weight',
          subtitle: r.targetWeightKg == null ? 'Your trend over ${r.days} days' : 'Target ${formatNumber(r.targetWeightKg!)} kg',
          action: 'Log weight',
          onAction: () => _logWeight(b.latestWeight?.weightKg)),
      Row(children: [
        Expanded(
          child: MetricTile(
            label: 'Latest',
            value: b.latestWeight == null ? '--' : formatNumber(b.latestWeight!.weightKg),
            unit: b.latestWeight == null ? null : 'kg',
            icon: Icons.monitor_weight_rounded,
            color: AppColors.blue,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: MetricTile(
            label: 'Change in ${r.days} days',
            value: b.weightChangeKg == null ? '--' : '${b.weightChangeKg! > 0 ? '+' : ''}${formatNumber(b.weightChangeKg!)}',
            unit: b.weightChangeKg == null ? null : 'kg',
            icon: (b.weightChangeKg ?? 0) <= 0 ? Icons.trending_down_rounded : Icons.trending_up_rounded,
            color: AppColors.purple,
          ),
        ),
      ]),
      const SizedBox(height: 12),
      _ChartCard(
        title: 'Weight trend',
        child: b.weightSeries.length < 2
            ? _ChartEmpty(
                icon: Icons.show_chart_rounded,
                text: 'Log your weight on 2+ days to see a trend',
                cta: 'Log weight',
                onTap: () => _logWeight(b.latestWeight?.weightKg),
              )
            : _WeightChart(points: b.weightSeries),
      ),
      const SizedBox(height: 12),
      _BmiCard(bmi: r.bmi, category: r.bmiCategory, onSetGoal: _editGoal),
    ];
  }
}

// ---------------------------------------------------------------------------
// Goal-based pieces
// ---------------------------------------------------------------------------

({String label, Color color, IconData icon}) _statusVisual(String status) => switch (status) {
      'ahead' => (label: 'Ahead', color: AppColors.green, icon: Icons.trending_up_rounded),
      'on_track' => (label: 'On track', color: AppColors.blue, icon: Icons.check_rounded),
      'behind' => (label: 'Behind', color: AppColors.amber, icon: Icons.trending_down_rounded),
      _ => (label: 'No data', color: AppColors.text3, icon: Icons.remove_rounded),
    };

class _StatusTag extends StatelessWidget {
  const _StatusTag(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final v = _statusVisual(status);
    return Tag(v.label, color: v.color, icon: v.icon, dense: true);
  }
}

class _WeekCard extends StatelessWidget {
  const _WeekCard({required this.title, required this.score, required this.insight});
  final String title;
  final int? score;
  final String insight;

  @override
  Widget build(BuildContext context) {
    final s = (score ?? 0).clamp(0, 100);
    final color = score == null
        ? AppColors.text3
        : s >= 80
            ? AppColors.green
            : s >= 50
                ? AppColors.blue
                : AppColors.primary;
    return AppCard(
      padding: const EdgeInsets.all(18),
      radius: 22,
      child: Row(children: [
        SizedBox(
          width: 92,
          height: 92,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: s / 100),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Stack(alignment: Alignment.center, children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: v,
                  strokeWidth: 9,
                  strokeCap: StrokeCap.round,
                  backgroundColor: color.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text(score == null ? '--' : '${(v * 100).round()}',
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1)),
                const Text('score', style: TextStyle(fontSize: 11, color: AppColors.text3, fontWeight: FontWeight.w700)),
              ]),
            ]),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title.toUpperCase(),
                style: const TextStyle(
                    fontSize: 11.5, letterSpacing: 0.8, color: AppColors.text3, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(insight, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, height: 1.3)),
          ]),
        ),
      ]),
    );
  }
}

class _GoalRingTile extends StatelessWidget {
  const _GoalRingTile({required this.ring, required this.onTap});
  final GoalRing ring;
  final VoidCallback onTap;

  static const _icons = {
    'workout_days': (Icons.fitness_center_rounded, AppColors.primary),
    'steps': (Icons.directions_walk_rounded, AppColors.amber),
    'calories': (Icons.local_dining_rounded, AppColors.green),
    'protein': (Icons.egg_alt_rounded, AppColors.purple),
  };

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _icons[ring.key] ?? (Icons.flag_rounded, AppColors.blue);
    final p = ring.progress.clamp(0.0, 1.0);
    final value = ring.hasData ? _n(ring.value) : '--';
    final unit = switch (ring.key) {
      'workout_days' => 'of ${ring.target.round()} days/wk',
      'steps' => 'of ${_n(ring.target)}',
      'calories' => 'of ${_n(ring.target)} kcal',
      _ => 'of ${_n(ring.target)} g',
    };
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      radius: 18,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(
            width: 52,
            height: 52,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: ring.hasData ? p : 0,
                  strokeWidth: 6,
                  strokeCap: StrokeCap.round,
                  backgroundColor: color.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
              Icon(icon, color: color, size: 20),
            ]),
          ),
          const Spacer(),
          _StatusTag(ring.status),
        ]),
        const SizedBox(height: 10),
        Text(ring.label, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        Text(unit,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _TabLinkCard extends StatelessWidget {
  const _TabLinkCard({
    required this.image,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });
  final String image;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.asset(image, width: 64, height: 64, fit: BoxFit.cover),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
            const SizedBox(height: 3),
            Text(subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
          ]),
        ),
        Icon(Icons.chevron_right_rounded, color: color),
      ]),
    );
  }
}

class _BurnCard extends StatelessWidget {
  const _BurnCard({required this.burned, required this.days});
  final CaloriesBurned burned;
  final int days;

  @override
  Widget build(BuildContext context) {
    final rows = [
      if (burned.fromActivities > 0) ('Logged activities', burned.fromActivities, AppColors.primary),
      if (burned.fromGymVisits > 0) ('Gym visits (est. 60 min)', burned.fromGymVisits, AppColors.purple),
      if (burned.fromSteps > 0) ('Steps', burned.fromSteps, AppColors.amber),
      if (burned.fromDevice > 0)
        ('Measured by your phone / watch (${burned.measuredDays} day${burned.measuredDays == 1 ? '' : 's'})', burned.fromDevice, AppColors.green),
    ];
    final weightNote = switch (burned.weightSource) {
      'weight_log' => 'your latest weight',
      'goal' => 'your goal weight',
      _ => 'a default weight — log yours for accuracy',
    };
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_n(burned.total), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -1)),
          const SizedBox(width: 6),
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('kcal', style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700)),
          ),
          const Spacer(),
          Tag('${_n(burned.avgPerDay)} / day', color: AppColors.red, icon: Icons.local_fire_department_rounded, dense: true),
        ]),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          const Text('Log a workout, check in or sync steps — we estimate the calories for you.',
              style: TextStyle(color: AppColors.text2, fontSize: 13))
        else
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: row.$3, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(row.$1,
                      style: const TextStyle(color: AppColors.text2, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                Text('${_n(row.$2)} kcal', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              ]),
            ),
        const SizedBox(height: 8),
        Text('Estimates use MET × ${formatNumber(burned.weightKgUsed)} kg ($weightNote) × hours.',
            style: const TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

class _MacroRow extends StatelessWidget {
  const _MacroRow(this.label, this.grams, this.target, this.color);
  final String label;
  final double grams;
  final int target;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ratio = target > 0 ? grams / target : 0.0;
    final diff = (ratio - 1) * 100;
    final note = target <= 0
        ? ''
        : diff.abs() <= 10
            ? 'on target'
            : diff < 0
                ? '${diff.abs().round()}% low'
                : '${diff.round()}% high';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
        const Spacer(),
        Text.rich(TextSpan(children: [
          TextSpan(text: '${formatNumber(grams)}g', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
          TextSpan(
              text: ' / ${target}g · $note',
              style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
        ])),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: LinearProgressIndicator(
          value: ratio.clamp(0.0, 1.0),
          minHeight: 7,
          backgroundColor: color.withValues(alpha: 0.12),
          valueColor: AlwaysStoppedAnimation(color),
        ),
      ),
    ]);
  }
}

class _WaterCard extends StatelessWidget {
  const _WaterCard({
    required this.today,
    required this.target,
    required this.avg,
    required this.daysHit,
    required this.loggedDays,
    required this.busy,
    required this.onAdd,
    required this.onRemove,
  });
  final int today;
  final int target;
  final double avg;
  final int daysHit;
  final int loggedDays;
  final bool busy;
  final VoidCallback onAdd;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final p = target > 0 ? (today / target).clamp(0.0, 1.0) : 0.0;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          IconBubble(Icons.water_drop_rounded, color: AppColors.blue, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Today', style: TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w700)),
              Text.rich(TextSpan(children: [
                TextSpan(text: '$today', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                TextSpan(
                    text: ' / $target glasses',
                    style: const TextStyle(color: AppColors.text3, fontSize: 13, fontWeight: FontWeight.w700)),
              ])),
            ]),
          ),
          _RoundBtn(icon: Icons.remove_rounded, onTap: busy ? null : onRemove),
          const SizedBox(width: 10),
          _RoundBtn(icon: Icons.add_rounded, filled: true, onTap: busy ? null : onAdd),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          for (var i = 0; i < math.min(target, 12); i++)
            Expanded(
              child: Container(
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: i < (p * math.min(target, 12)).round() ? AppColors.blue : AppColors.blueSoft,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 10),
        Text(
          loggedDays == 0
              ? 'Tap + each time you finish a glass (~250 ml).'
              : 'Avg ${formatNumber(avg)} glasses on $loggedDays logged day${loggedDays == 1 ? '' : 's'} · goal hit $daysHit×',
          style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ]),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.onTap, this.filled = false});
  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tap(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: filled && enabled ? AppColors.blue : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: filled && enabled ? Colors.white : (enabled ? AppColors.text : AppColors.text3)),
      ),
    );
  }
}

class _BmiCard extends StatelessWidget {
  const _BmiCard({required this.bmi, required this.category, required this.onSetGoal});
  final double? bmi;
  final String? category;
  final VoidCallback onSetGoal;

  @override
  Widget build(BuildContext context) {
    if (bmi == null) {
      return _NudgeCard(
        image: AppImages.yoga,
        title: 'See your BMI',
        message: 'Add your height in your goal to calculate your BMI.',
        cta: 'Set goal',
        onTap: onSetGoal,
      );
    }
    final color = switch (category) {
      'Healthy' => AppColors.green,
      'Underweight' => AppColors.blue,
      'Overweight' => AppColors.amber,
      _ => AppColors.red,
    };
    // Position on an 15–35 scale.
    final pos = ((bmi! - 15) / 20).clamp(0.0, 1.0);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('BMI', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const Spacer(),
          Tag(category ?? '', color: color, dense: true),
        ]),
        const SizedBox(height: 6),
        Text(bmi!.toStringAsFixed(1), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, c) => Stack(clipBehavior: Clip.none, children: [
            Row(children: const [
              Expanded(flex: 35, child: _BmiBand(AppColors.blue)),
              Expanded(flex: 65, child: _BmiBand(AppColors.green)),
              Expanded(flex: 50, child: _BmiBand(AppColors.amber)),
              Expanded(flex: 50, child: _BmiBand(AppColors.red)),
            ]),
            Positioned(
              left: (c.maxWidth * pos - 7).clamp(0.0, c.maxWidth - 14),
              top: -4,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.ink, width: 3),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        const Text('Under 18.5 · 18.5–25 healthy · 25–30 · 30+',
            style: TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _BmiBand extends StatelessWidget {
  const _BmiBand(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        height: 6,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(3)),
      );
}

/// Daily (≤30 days) or weekly-average (longer) bars with a dashed goal line.
class _TrendBars extends StatelessWidget {
  const _TrendBars({
    required this.points,
    required this.target,
    required this.color,
    required this.unit,
    this.highlightAtTarget = true,
  });
  final List<(DateTime, double)> points;

  /// Bars at/above the goal get the full colour (steps); off for calories, where more isn't better.
  final bool highlightAtTarget;
  final double target;
  final Color color;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final weekly = points.length > 31;
    final buckets = <(DateTime, double)>[];
    if (weekly) {
      for (var end = points.length; end > 0; end -= 7) {
        final slice = points.sublist(math.max(0, end - 7), end);
        final logged = slice.where((p) => p.$2 > 0).toList();
        final avg = logged.isEmpty ? 0.0 : logged.fold<double>(0, (a, p) => a + p.$2) / logged.length;
        buckets.insert(0, (slice.first.$1, avg));
      }
    } else {
      buckets.addAll(points);
    }
    if (buckets.isEmpty) return const SizedBox.shrink();
    final maxV = buckets.fold<double>(target, (a, b) => math.max(a, b.$2));
    final maxY = maxV <= 0 ? 1.0 : maxV * 1.15;
    final labelEvery = buckets.length <= 7 ? 1 : (buckets.length / 5).ceil();
    final barWidth = buckets.length > 20 ? 6.0 : (buckets.length > 10 ? 12.0 : 22.0);

    return BarChart(BarChartData(
      maxY: maxY,
      alignment: BarChartAlignment.spaceAround,
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      extraLinesData: ExtraLinesData(horizontalLines: [
        if (target > 0)
          HorizontalLine(
            y: target,
            color: AppColors.text3,
            strokeWidth: 1.2,
            dashArray: [5, 4],
            label: HorizontalLineLabel(
              show: true,
              alignment: Alignment.topRight,
              style: _axisStyle,
              labelResolver: (_) => 'Goal ${_n(target)}',
            ),
          ),
      ]),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => AppColors.ink,
          tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          getTooltipItem: (group, _, rod, _) {
            final b = buckets[group.x];
            final when = weekly ? 'Week of ${formatShortDate(b.$1)} · avg' : formatShortDate(b.$1);
            return BarTooltipItem(
              '$when\n',
              const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
              children: [
                TextSpan(
                  text: '${_n(b.$2.round())} $unit',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5),
                ),
              ],
            );
          },
        ),
      ),
      titlesData: FlTitlesData(
        rightTitles: const AxisTitles(),
        topTitles: const AxisTitles(),
        leftTitles: const AxisTitles(),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 24,
            getTitlesWidget: (value, meta) {
              final i = value.toInt();
              if (i < 0 || i >= buckets.length) return const SizedBox.shrink();
              final isLast = i == buckets.length - 1;
              if (!isLast && (i % labelEvery != 0 || buckets.length - 1 - i < labelEvery ~/ 2 + 1)) {
                return const SizedBox.shrink();
              }
              final label = !weekly && buckets.length <= 7
                  ? ['M', 'T', 'W', 'T', 'F', 'S', 'S'][buckets[i].$1.weekday - 1]
                  : formatShortDate(buckets[i].$1);
              return Padding(padding: const EdgeInsets.only(top: 6), child: Text(label, style: _axisStyle));
            },
          ),
        ),
      ),
      barGroups: [
        for (var i = 0; i < buckets.length; i++)
          BarChartGroupData(x: i, barRods: [
            BarChartRodData(
              toY: buckets[i].$2,
              width: barWidth,
              color: buckets[i].$2 <= 0
                  ? AppColors.surfaceAlt
                  : (!highlightAtTarget || (target > 0 && buckets[i].$2 >= target) ? color : color.withValues(alpha: 0.55)),
              borderRadius: BorderRadius.circular(barWidth / 2),
              backDrawRodData: BackgroundBarChartRodData(show: true, toY: maxY, color: AppColors.bg),
            ),
          ]),
      ],
    ));
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _ReportSkeleton extends StatelessWidget {
  const _ReportSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: const [
          Row(children: [
            Expanded(child: SkeletonBox(height: 170, radius: 20)),
            SizedBox(width: 12),
            Expanded(child: SkeletonBox(height: 170, radius: 20)),
          ]),
          SizedBox(height: 14),
          SkeletonBox(height: 74, radius: 18),
          SizedBox(height: 28),
          SkeletonBox(height: 18, width: 140),
          SizedBox(height: 14),
          Row(children: [
            Expanded(child: SkeletonBox(height: 100, radius: 18)),
            SizedBox(width: 10),
            Expanded(child: SkeletonBox(height: 100, radius: 18)),
          ]),
          SizedBox(height: 12),
          SkeletonBox(height: 220, radius: 20),
        ],
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      for (var i = 0; i < children.length; i += 2) ...[
        if (i > 0) const SizedBox(height: 10),
        Row(children: [
          Expanded(child: children[i]),
          const SizedBox(width: 10),
          Expanded(child: i + 1 < children.length ? children[i + 1] : const SizedBox()),
        ]),
      ],
    ]);
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({
    required this.score,
    required this.title,
    required this.caption,
    required this.color,
    required this.icon,
  });

  final int score;
  final String title;
  final String caption;
  final Color color;
  final IconData icon;

  String get _verdict => score >= 80
      ? 'Excellent'
      : score >= 50
          ? 'On track'
          : score > 0
              ? 'Building up'
              : 'Get started';

  @override
  Widget build(BuildContext context) {
    final s = score.clamp(0, 100);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      child: Column(children: [
        SizedBox(
          width: 96,
          height: 96,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: s / 100),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Stack(alignment: Alignment.center, children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: v,
                  strokeWidth: 9,
                  strokeCap: StrokeCap.round,
                  backgroundColor: color.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${(v * 100).round()}',
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1)),
                const Text('/100', style: TextStyle(fontSize: 11, color: AppColors.text3, fontWeight: FontWeight.w700)),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
          ),
        ]),
        const SizedBox(height: 4),
        Tag(_verdict, color: color, dense: true),
        const SizedBox(height: 6),
        Text(caption,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: const TextStyle(color: AppColors.text2, fontSize: 11.5, fontWeight: FontWeight.w500, height: 1.3)),
      ]),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.color, required this.onTap, this.busy = false});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: busy ? null : onTap,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      radius: 18,
      child: Column(children: [
        busy
            ? SizedBox(
                width: 40,
                height: 40,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: CircularProgressIndicator(strokeWidth: 2.5, valueColor: AlwaysStoppedAnimation(color)),
                ),
              )
            : IconBubble(icon, color: color, size: 40),
        const SizedBox(height: 8),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
      ]),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
          ?trailing,
        ]),
        const SizedBox(height: 18),
        SizedBox(height: 170, child: child),
      ]),
    );
  }
}

class _ChartEmpty extends StatelessWidget {
  const _ChartEmpty({required this.icon, required this.text, this.cta, this.onTap});
  final IconData icon;
  final String text;
  final String? cta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        IconBubble(icon, color: AppColors.text3, bg: AppColors.surfaceAlt, size: 48),
        const SizedBox(height: 10),
        Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600, fontSize: 13)),
        if (cta != null) ...[
          const SizedBox(height: 6),
          TextButton(onPressed: onTap, child: Text(cta!)),
        ],
      ]),
    );
  }
}

class _NudgeCard extends StatelessWidget {
  const _NudgeCard({required this.image, required this.title, required this.message, required this.cta, required this.onTap});
  final String image;
  final String title;
  final String message;
  final String cta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.asset(image, width: 76, height: 76, fit: BoxFit.cover),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 3),
            Text(message, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
            const SizedBox(height: 6),
            Row(children: [
              Text(cta, style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 13)),
              const Icon(Icons.chevron_right_rounded, color: AppColors.primary, size: 18),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _TopVenueRow extends StatelessWidget {
  const _TopVenueRow({required this.rank, required this.name, required this.visits, required this.max});
  final int rank;
  final String name;
  final int visits;
  final int max;

  @override
  Widget build(BuildContext context) {
    final medal = switch (rank) { 1 => AppColors.amber, 2 => AppColors.text3, 3 => AppColors.primaryDeep, _ => AppColors.line };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: medal.withValues(alpha: 0.15), shape: BoxShape.circle),
          child: Text('$rank', style: TextStyle(fontWeight: FontWeight.w800, color: rank <= 3 ? medal : AppColors.text2)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: max == 0 ? 0 : visits / max,
                minHeight: 5,
                backgroundColor: AppColors.surfaceAlt,
                valueColor: const AlwaysStoppedAnimation(AppColors.green),
              ),
            ),
          ]),
        ),
        const SizedBox(width: 12),
        Text('$visits ${visits == 1 ? 'visit' : 'visits'}',
            style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700, fontSize: 12.5)),
      ]),
    );
  }
}

class _TypeRow extends StatelessWidget {
  const _TypeRow({required this.type, required this.count, required this.minutes, required this.max});
  final String type;
  final int count;
  final int minutes;
  final int max;

  @override
  Widget build(BuildContext context) {
    final v = activityVisual(type);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        IconBubble(v.icon, color: v.color, bg: v.soft, size: 38),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(v.label, style: const TextStyle(fontWeight: FontWeight.w700))),
              Text('$count× · $minutes min',
                  style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600, fontSize: 12.5)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: max == 0 ? 0 : count / max,
                minHeight: 6,
                backgroundColor: v.soft,
                valueColor: AlwaysStoppedAnimation(v.color),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Charts
// ---------------------------------------------------------------------------

const _axisStyle = TextStyle(fontSize: 10, color: AppColors.text3, fontWeight: FontWeight.w600);

class _CheckinChart extends StatelessWidget {
  const _CheckinChart({required this.report});

  final HealthReport report;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final days = List.generate(report.days, (i) => today.subtract(Duration(days: report.days - 1 - i)));
    final weekly = report.days > 30;

    // Buckets: one per day, or one per 7 days (ending today) for long periods.
    final buckets = <(DateTime, int)>[];
    if (weekly) {
      for (var end = days.length; end > 0; end -= 7) {
        final start = math.max(0, end - 7);
        final slice = days.sublist(start, end);
        buckets.insert(0, (slice.first, slice.fold<int>(0, (a, d) => a + (report.checkinsPerDay[d] ?? 0))));
      }
    } else {
      for (final d in days) {
        buckets.add((d, report.checkinsPerDay[d] ?? 0));
      }
    }
    final maxCount = buckets.fold<int>(0, (a, b) => math.max(a, b.$2));
    final maxY = math.max(2, maxCount + 1).toDouble();
    final labelEvery = buckets.length <= 7 ? 1 : (buckets.length / 5).ceil();
    final barWidth = buckets.length > 20 ? 6.0 : (buckets.length > 10 ? 12.0 : 22.0);

    return BarChart(BarChartData(
      maxY: maxY,
      alignment: BarChartAlignment.spaceAround,
      gridData: FlGridData(
        drawVerticalLine: false,
        horizontalInterval: math.max(1, (maxY / 4).ceilToDouble()),
        getDrawingHorizontalLine: (_) => const FlLine(color: AppColors.line, strokeWidth: 1, dashArray: [4, 4]),
      ),
      borderData: FlBorderData(show: false),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => AppColors.ink,
          tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          getTooltipItem: (group, _, rod, _) {
            final b = buckets[group.x];
            final when = weekly ? 'Week of ${formatShortDate(b.$1)}' : formatShortDate(b.$1);
            return BarTooltipItem(
              '$when\n',
              const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
              children: [
                TextSpan(
                  text: '${b.$2} check-in${b.$2 == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5),
                ),
              ],
            );
          },
        ),
      ),
      titlesData: FlTitlesData(
        rightTitles: const AxisTitles(),
        topTitles: const AxisTitles(),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 24,
            interval: math.max(1, (maxY / 4).ceilToDouble()),
            getTitlesWidget: (v, meta) =>
                v == meta.max ? const SizedBox.shrink() : Text(v.toInt().toString(), style: _axisStyle),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 24,
            getTitlesWidget: (value, meta) {
              final i = value.toInt();
              if (i < 0 || i >= buckets.length) return const SizedBox.shrink();
              final isLast = i == buckets.length - 1;
              if (!isLast && (i % labelEvery != 0 || buckets.length - 1 - i < labelEvery ~/ 2 + 1)) {
                return const SizedBox.shrink();
              }
              final label = !weekly && buckets.length <= 7
                  ? ['M', 'T', 'W', 'T', 'F', 'S', 'S'][buckets[i].$1.weekday - 1]
                  : formatShortDate(buckets[i].$1);
              return Padding(padding: const EdgeInsets.only(top: 6), child: Text(label, style: _axisStyle));
            },
          ),
        ),
      ),
      barGroups: [
        for (var i = 0; i < buckets.length; i++)
          BarChartGroupData(x: i, barRods: [
            BarChartRodData(
              toY: buckets[i].$2.toDouble(),
              width: barWidth,
              gradient: buckets[i].$2 > 0
                  ? const LinearGradient(
                      colors: [Color(0xFFFF8A5C), AppColors.primary],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    )
                  : null,
              color: buckets[i].$2 > 0 ? null : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(barWidth / 2),
              backDrawRodData: BackgroundBarChartRodData(show: true, toY: maxY, color: AppColors.bg),
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
    final maxX = spots.last.x;

    return LineChart(LineChartData(
      minY: minY,
      maxY: maxY,
      minX: 0,
      maxX: maxX == 0 ? 1 : maxX,
      gridData: FlGridData(
        drawVerticalLine: false,
        getDrawingHorizontalLine: (_) => const FlLine(color: AppColors.line, strokeWidth: 1, dashArray: [4, 4]),
      ),
      borderData: FlBorderData(show: false),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => AppColors.ink,
          tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          getTooltipItems: (touched) => touched.map((s) {
            final date = first.add(Duration(days: s.x.round()));
            return LineTooltipItem(
              '${formatShortDate(date)}\n',
              const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
              children: [
                TextSpan(
                  text: '${s.y.toStringAsFixed(1)} kg',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5),
                ),
              ],
            );
          }).toList(),
        ),
      ),
      titlesData: FlTitlesData(
        rightTitles: const AxisTitles(),
        topTitles: const AxisTitles(),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 24,
            interval: maxX == 0 ? 1 : maxX,
            getTitlesWidget: (v, meta) {
              final date = first.add(Duration(days: v.round()));
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(formatShortDate(date), style: _axisStyle),
              );
            },
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 32,
            getTitlesWidget: (v, meta) => Text(v.toStringAsFixed(0), style: _axisStyle),
          ),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          preventCurveOverShooting: true,
          color: AppColors.blue,
          barWidth: 3,
          isStrokeCapRound: true,
          dotData: FlDotData(
            show: spots.length < 20,
            getDotPainter: (spot, _, _, _) => FlDotCirclePainter(
              radius: 3.5,
              color: Colors.white,
              strokeWidth: 2.5,
              strokeColor: AppColors.blue,
            ),
          ),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.blue.withValues(alpha: 0.22), AppColors.blue.withValues(alpha: 0.0)],
            ),
          ),
        ),
      ],
    ));
  }
}
