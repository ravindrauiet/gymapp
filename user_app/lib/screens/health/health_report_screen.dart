import 'dart:math' as math;

import 'package:fitkey_core/fitkey_core.dart' show formatNumber, formatShortDate;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../goals/goal_selection_screen.dart';
import '../nutrition/fuel_log_screen.dart';
import 'attendance_screen.dart';
import 'log_sheets.dart';
import 'step_sync_sheet.dart';

/// U9 — Health / gym report: attendance, movement, workouts, weight and nutrition.
class HealthReportScreen extends StatefulWidget {
  const HealthReportScreen({super.key});

  @override
  State<HealthReportScreen> createState() => _HealthReportScreenState();
}

class _HealthReportScreenState extends State<HealthReportScreen> {
  static const _periods = [7, 30, 90];
  int _days = 30;
  late Future<HealthReport> _future = _load();

  Future<HealthReport> _load() => context.read<Session>().api.healthReport(days: _days);

  void _reload() => setState(() => _future = _load());

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f;
  }

  Future<void> _logActivity() async {
    if (await showActivitySheet(context)) {
      if (!mounted) return;
      toast(context, 'Activity logged');
      _reload();
    }
  }

  Future<void> _logWeight(double? current) async {
    if (await showWeightSheet(context, current: current)) {
      if (!mounted) return;
      toast(context, 'Weight saved');
      _reload();
    }
  }

  Future<void> _syncSteps() async {
    final updated = await showAppSheet<bool>(context, builder: (_) => const StepSyncSheet());
    if (updated == true && mounted) _reload();
  }

  Future<void> _open(Widget screen) async {
    await push(context, screen);
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My progress'),
        actions: [
          IconButton(
            tooltip: 'Activity log',
            icon: const Icon(Icons.history_rounded),
            onPressed: () => _open(const ActivityLogScreen()),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [
        Container(
          color: AppColors.surface,
          padding: const EdgeInsets.only(bottom: 12, top: 4),
          child: ChoiceChips<int>(
            options: _periods,
            selected: _days,
            label: (d) => 'Last $d days',
            icon: (d) => d == _days ? Icons.calendar_today_rounded : null,
            onSelected: (d) {
              if (d == _days) return;
              _days = d;
              _reload();
            },
          ),
        ),
        Expanded(
          child: FutureBuilder<HealthReport>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const _ReportSkeleton();
              if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
              return RefreshIndicator(color: AppColors.primary, onRefresh: _refresh, child: _report(snap.data!));
            },
          ),
        ),
      ]),
    );
  }

  Widget _report(HealthReport r) {
    final m = r.movement;
    final n = r.nutrition;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
      children: [
        // ---- Hero scores ----
        Row(children: [
          Expanded(
            child: _ScoreCard(
              score: r.gymConsistencyScore,
              title: 'Gym consistency',
              caption: '${r.totalCheckins} check-ins · ${r.currentStreak}-day streak',
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
                  ? 'Add steps to get scored'
                  : '${formatNumber(m.avgDailySteps)} steps / day',
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
              icon: Icons.monitor_weight_rounded,
              label: 'Log weight',
              color: AppColors.blue,
              onTap: () => _logWeight(r.latestWeight?.weightKg),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _QuickAction(
                icon: Icons.directions_walk_rounded, label: 'Add steps', color: AppColors.amber, onTap: _syncSteps),
          ),
        ]),

        // ---- Attendance ----
        SectionTitle('Attendance',
            subtitle: 'Your gym visits in the last ${r.days} days',
            action: 'History',
            onAction: () => push(context, const AttendanceScreen())),
        _Grid(children: [
          MetricTile(label: 'Check-ins', value: '${r.totalCheckins}', icon: Icons.login_rounded, color: AppColors.green),
          MetricTile(
              label: 'Current streak',
              value: '${r.currentStreak}',
              unit: r.currentStreak == 1 ? 'day' : 'days',
              icon: Icons.local_fire_department_rounded,
              color: AppColors.primary),
          MetricTile(label: 'Active days', value: '${r.activeDays}', icon: Icons.calendar_month_rounded, color: AppColors.blue),
          MetricTile(label: 'Venues visited', value: '${r.uniqueVenues}', icon: Icons.place_rounded, color: AppColors.purple),
        ]),
        const SizedBox(height: 12),
        _ChartCard(
          title: r.days > 30 ? 'Check-ins per week' : 'Check-ins per day',
          trailing: Tag('${r.totalCheckins} total', color: AppColors.primary, dense: true),
          child: r.totalCheckins == 0
              ? const _ChartEmpty(icon: Icons.qr_code_scanner_rounded, text: 'Check in at a venue to fill this chart')
              : _CheckinChart(report: r),
        ),
        if (r.topVenues.isNotEmpty) ...[
          const SizedBox(height: 12),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Favourite venues', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 6),
              for (var i = 0; i < r.topVenues.length; i++)
                _TopVenueRow(
                  rank: i + 1,
                  name: r.topVenues[i].name,
                  visits: r.topVenues[i].visits,
                  max: r.topVenues.first.visits,
                ),
            ]),
          ),
        ],

        // ---- Movement ----
        SectionTitle('Movement',
            subtitle: 'Steps, distance and active burn', action: 'Add steps', onAction: _syncSteps),
        if (m == null || m.totalSteps == 0)
          _NudgeCard(
            image: AppImages.running,
            title: 'Track your daily steps',
            message: 'Add today\'s step count from your phone to unlock your movement score.',
            cta: 'Add steps',
            onTap: _syncSteps,
          )
        else
          Row(children: [
            Expanded(
              child: MetricTile(
                  label: 'Avg steps / day',
                  value: formatNumber(m.avgDailySteps),
                  icon: Icons.directions_walk_rounded,
                  color: AppColors.amber),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MetricTile(
                  label: 'Distance',
                  value: formatNumber(m.totalDistanceKm),
                  unit: 'km',
                  icon: Icons.route_rounded,
                  color: AppColors.teal),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MetricTile(
                  label: 'Active burn',
                  value: formatNumber(m.totalActiveBurn),
                  unit: 'kcal',
                  icon: Icons.whatshot_rounded,
                  color: AppColors.red),
            ),
          ]),

        // ---- Workouts ----
        SectionTitle('Workouts',
            subtitle: 'Sessions you logged', action: 'Log', onAction: _logActivity),
        _Grid(children: [
          MetricTile(label: 'Sessions', value: '${r.workoutCount}', icon: Icons.bolt_rounded, color: AppColors.primary),
          MetricTile(
              label: 'Minutes', value: formatNumber(r.totalMinutes), icon: Icons.timer_rounded, color: AppColors.purple),
          MetricTile(
              label: 'Distance',
              value: formatNumber(r.totalDistanceKm),
              unit: 'km',
              icon: Icons.route_rounded,
              color: AppColors.teal),
          MetricTile(
              label: 'Calories',
              value: formatNumber(r.totalCalories),
              unit: 'kcal',
              icon: Icons.local_fire_department_rounded,
              color: AppColors.red),
        ]),
        const SizedBox(height: 12),
        if (r.workoutsByType.isEmpty)
          _NudgeCard(
            image: AppImages.strength,
            title: 'No workouts logged yet',
            message: 'Log a workout, run or yoga session — it all adds up here.',
            cta: 'Log activity',
            onTap: _logActivity,
          )
        else
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(
                  child: Text('By activity', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                ),
                Tap(
                  onTap: () => _open(const ActivityLogScreen()),
                  child: const Text('See log',
                      style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 13)),
                ),
              ]),
              const SizedBox(height: 8),
              for (final t in r.workoutsByType)
                _TypeRow(
                  type: t.type,
                  count: t.count,
                  minutes: t.minutes,
                  max: r.workoutsByType.map((e) => e.count).reduce(math.max),
                ),
            ]),
          ),

        // ---- Weight ----
        SectionTitle('Weight',
            subtitle: 'Your trend over ${r.days} days',
            action: 'Log weight',
            onAction: () => _logWeight(r.latestWeight?.weightKg)),
        Row(children: [
          Expanded(
            child: MetricTile(
              label: 'Latest',
              value: r.latestWeight == null ? '--' : formatNumber(r.latestWeight!.weightKg),
              unit: r.latestWeight == null ? null : 'kg',
              icon: Icons.monitor_weight_rounded,
              color: AppColors.blue,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: MetricTile(
              label: 'Change in ${r.days} days',
              value: r.weightChangeKg == null
                  ? '--'
                  : '${r.weightChangeKg! > 0 ? '+' : ''}${formatNumber(r.weightChangeKg!)}',
              unit: r.weightChangeKg == null ? null : 'kg',
              icon: (r.weightChangeKg ?? 0) <= 0 ? Icons.trending_down_rounded : Icons.trending_up_rounded,
              color: AppColors.purple,
            ),
          ),
        ]),
        const SizedBox(height: 12),
        _ChartCard(
          title: 'Weight trend',
          child: r.weightSeries.length < 2
              ? _ChartEmpty(
                  icon: Icons.show_chart_rounded,
                  text: 'Log your weight on 2+ days to see a trend',
                  cta: 'Log weight',
                  onTap: () => _logWeight(r.latestWeight?.weightKg),
                )
              : _WeightChart(points: r.weightSeries),
        ),

        // ---- Nutrition ----
        SectionTitle('Nutrition',
            subtitle: 'Average daily intake from your Fuel Log',
            action: 'Fuel Log',
            onAction: () => _open(const FuelLogScreen())),
        if (n == null || n.avgDailyCalories == 0)
          _NudgeCard(
            image: AppImages.foodBowl,
            title: 'Log your meals',
            message: 'Track what you eat to see calories and macros against your goal.',
            cta: 'Open Fuel Log',
            onTap: () => _open(const FuelLogScreen()),
          )
        else
          _NutritionCard(n: n, onEditGoal: () => _open(const GoalSelectionScreen(isEditing: true))),
      ],
    );
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
  const _QuickAction({required this.icon, required this.label, required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      radius: 18,
      child: Column(children: [
        IconBubble(icon, color: color, size: 40),
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

class _NutritionCard extends StatelessWidget {
  const _NutritionCard({required this.n, required this.onEditGoal});
  final NutritionReport n;
  final VoidCallback onEditGoal;

  @override
  Widget build(BuildContext context) {
    final status = n.deficitSurplusStatus;
    final statusColor = status.startsWith('Deficit')
        ? AppColors.blue
        : status.startsWith('Surplus')
            ? AppColors.amber
            : AppColors.green;
    final ratio = n.dailyCalorieBaseline == 0 ? 0.0 : (n.avgDailyCalories / n.dailyCalorieBaseline).clamp(0.0, 1.0);
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SizedBox(
            height: 96,
            child: Stack(fit: StackFit.expand, children: [
              Image.asset(AppImages.foodPlate, fit: BoxFit.cover),
              const PhotoScrim(strength: 0.8, from: Alignment.centerRight),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text.rich(TextSpan(children: [
                        TextSpan(
                            text: formatNumber(n.avgDailyCalories),
                            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
                        const TextSpan(text: ' kcal / day', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                      ]), style: const TextStyle(color: Colors.white)),
                      Text('Logged on ${n.mealDays} ${n.mealDays == 1 ? 'day' : 'days'}',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600)),
                    ]),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Tag(status, color: statusColor),
              const Spacer(),
              Tap(
                onTap: onEditGoal,
                child: const Row(children: [
                  Icon(Icons.flag_rounded, size: 16, color: AppColors.primary),
                  SizedBox(width: 4),
                  Text('Edit goal', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 13)),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Text('vs ${formatNumber(n.dailyCalorieBaseline)} kcal target',
                  style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600, fontSize: 12.5)),
              const Spacer(),
              Text('${(ratio * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 8,
                backgroundColor: AppColors.surfaceAlt,
                valueColor: AlwaysStoppedAnimation(statusColor),
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: _Macro(
                    'Protein',
                    n.avgDailyProtein,
                    AppColors.purple,
                    n.dailyProteinBaseline > 0 ? '/ ${n.dailyProteinBaseline}g' : null),
              ),
              Expanded(child: _Macro('Carbs', n.avgDailyCarbs, AppColors.amber, null)),
              Expanded(child: _Macro('Fats', n.avgDailyFat, AppColors.pink, null)),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _Macro extends StatelessWidget {
  const _Macro(this.label, this.grams, this.color, this.target);
  final String label;
  final double grams;
  final Color color;
  final String? target;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 4),
      Text.rich(TextSpan(children: [
        TextSpan(text: '${formatNumber(grams)}g', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        if (target != null)
          TextSpan(text: ' $target', style: const TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w600)),
      ])),
    ]);
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
