import 'dart:async';
import 'dart:math' as math;

import 'package:fitkey_core/fitkey_core.dart' show apiDate, formatDayDate, formatNumber;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/food_api.dart';
import '../../data/models.dart';
import '../../data/progress_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../ai/ai_coach_screen.dart';
import '../goals/goal_selection_screen.dart';
import 'ai_food_scanner.dart';
import 'barcode_scanner_screen.dart';

/// Fuel Log — the member's daily nutrition diary.
class FuelLogScreen extends StatefulWidget {
  const FuelLogScreen({super.key});

  @override
  State<FuelLogScreen> createState() => _FuelLogScreenState();
}

// ---------------------------------------------------------------------------
// Shared meal metadata + helpers (also used by the barcode scanner)
// ---------------------------------------------------------------------------

class _Meal {
  const _Meal(this.id, this.label, this.emoji, this.hint, this.color, this.soft);
  final String id;
  final String label;
  final String emoji;
  final String hint;
  final Color color;
  final Color soft;
}

const _meals = [
  _Meal('breakfast', 'Breakfast', '🍳', '7 – 10 AM', AppColors.amber, AppColors.amberSoft),
  _Meal('lunch', 'Lunch', '🍛', '12 – 3 PM', AppColors.green, AppColors.greenSoft),
  _Meal('snacks', 'Snacks', '🥪', '4 – 7 PM', AppColors.pink, AppColors.pinkSoft),
  _Meal('dinner', 'Dinner', '🥗', '7 – 10 PM', AppColors.purple, AppColors.purpleSoft),
];

_Meal _mealOf(String id) => _meals.firstWhere((m) => m.id == id, orElse: () => _meals.first);

/// Meal slot that best matches the current time of day.
String suggestedMealType([DateTime? now]) {
  final h = (now ?? DateTime.now()).hour;
  if (h < 11) return 'breakfast';
  if (h < 16) return 'lunch';
  if (h < 19) return 'snacks';
  return 'dinner';
}

/// A friendly emoji for a free-form food category.
String foodEmoji(String category, [String name = '']) {
  final s = '${category.toLowerCase()} ${name.toLowerCase()}';
  bool has(List<String> k) => k.any(s.contains);
  if (has(['whey', 'supplement', 'protein powder', 'scoop'])) return '🥤';
  if (has(['bar'])) return '🍫';
  if (has(['yogurt', 'curd', 'lassi', 'milk', 'dairy', 'paneer', 'cheese'])) return '🥛';
  if (has(['egg'])) return '🥚';
  if (has(['fish', 'salmon', 'seafood', 'prawn', 'tuna'])) return '🐟';
  if (has(['chicken', 'meat', 'mutton'])) return '🍗';
  if (has(['banana', 'fruit', 'apple', 'mango'])) return '🍌';
  if (has(['nut', 'almond', 'peanut', 'fat', 'spread'])) return '🥜';
  if (has(['dal', 'lentil', 'rajma', 'chana', 'legume'])) return '🫘';
  if (has(['rice', 'roti', 'grain', 'carb'])) return '🍚';
  if (has(['oat', 'muesli', 'cereal', 'breakfast'])) return '🥣';
  if (has(['veg', 'salad', 'greens'])) return '🥦';
  return '🍽️';
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Opens the "how much & which meal" sheet for [food] and logs it.
/// Resolves to `true` when the meal was logged.
Future<bool> showFoodLogSheet(
  BuildContext context,
  FoodItem food, {
  String? mealType,
  DateTime? date,
  String? eyebrow,
}) async {
  final logged = await showAppSheet<bool>(
    context,
    builder: (_) => _FoodLogPanel(
      food: food,
      initialMeal: mealType ?? suggestedMealType(),
      date: date,
      eyebrow: eyebrow,
    ),
  );
  return logged == true;
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class _FuelLogScreenState extends State<FuelLogScreen> {
  late DateTime _date = _day(DateTime.now());
  MealDailySummary? _data;
  Map<String, MealLogExtra> _extras = const {};
  int _unavailableItems = 0;
  UserGoal? _goal;
  bool _goalKnown = false;
  Object? _error;
  bool _loading = true;
  int _req = 0;
  final Set<String> _removed = {};
  int? _water;
  bool _waterBusy = false;

  bool get _isToday => _date == _day(DateTime.now());

  @override
  void initState() {
    super.initState();
    _load();
    _loadGoal();
  }

  Future<void> _load({bool silent = false}) async {
    final id = ++_req;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final day = await context.read<Session>().api.fuelDay(date: _isToday ? null : apiDate(_date));
      if (!mounted || id != _req) return;
      setState(() {
        _data = day.summary;
        _extras = day.extras;
        _unavailableItems = day.unavailableItems;
        _water = null;
        _removed.clear();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || id != _req) return;
      if (silent && _data != null) {
        toast(context, friendlyError(e), error: true);
      } else {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadGoal() async {
    try {
      final g = await context.read<Session>().api.goal();
      if (mounted) {
        setState(() {
          _goal = g;
          _goalKnown = true;
        });
      }
    } catch (_) {
      // The goal prompt is optional — the diary still works without it.
    }
  }

  void _selectDate(DateTime d) {
    if (d == _date) return;
    setState(() => _date = d);
    _load();
  }

  Future<void> _openGoal() async {
    await push(context, const GoalSelectionScreen(isEditing: true));
    if (!mounted) return;
    _loadGoal();
    _load(silent: true);
  }

  /// Scanners always log to today — jump back to today after they log.
  Future<void> _afterScannerLogged() async {
    if (!_isToday) {
      setState(() => _date = _day(DateTime.now()));
      await _load();
    } else {
      await _load(silent: true);
    }
  }

  Future<void> _openAiScanner([String? meal]) async {
    final logged = await push<bool>(context, AiFoodScannerScreen(defaultMealType: meal ?? suggestedMealType()));
    if (logged == true && mounted) _afterScannerLogged();
  }

  Future<void> _openBarcode([String? meal]) async {
    final logged = await push<bool>(context, BarcodeScannerScreen(defaultMealType: meal ?? suggestedMealType()));
    if (logged == true && mounted) _afterScannerLogged();
  }

  Future<void> _openAddFood(String meal) async {
    final result = await showAppSheet<_AddResult>(
      context,
      builder: (_) => _AddFoodSheet(mealType: meal, date: _isToday ? null : _date),
    );
    if (!mounted || result == null) return;
    switch (result) {
      case _AddResult.logged:
        _load(silent: true);
      case _AddResult.ai:
        _openAiScanner(meal);
      case _AddResult.barcode:
        _openBarcode(meal);
    }
  }

  Future<bool> _confirmDelete(MealLog m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this item?'),
        content: Text('"${m.foodName}" (${m.calories} kcal) will be removed from your log.',
            style: const TextStyle(color: AppColors.text2)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep', style: TextStyle(color: AppColors.text2))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove', style: TextStyle(color: AppColors.red))),
        ],
      ),
    );
    if (ok != true || !mounted) return false;
    try {
      await context.read<Session>().api.deleteMeal(m.id);
      return true;
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
      return false;
    }
  }

  Future<void> _addWater(int delta) async {
    final d = _data;
    if (d == null || _waterBusy) return;
    final current = _water ?? d.waterGlasses;
    if (current + delta < 0) return;
    setState(() {
      _waterBusy = true;
      _water = current + delta;
    });
    try {
      final w = await context.read<Session>().api.addWater(delta, date: _isToday ? null : apiDate(_date));
      if (!mounted) return;
      HapticFeedback.selectionClick();
      setState(() => _water = w.glasses);
    } catch (e) {
      if (!mounted) return;
      setState(() => _water = current);
      toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _waterBusy = false);
    }
  }

  void _onDeleted(MealLog m) {
    setState(() => _removed.add(m.id));
    toast(context, 'Removed ${m.foodName}', icon: Icons.delete_outline_rounded);
    _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Fuel Log'),
        actions: [
          IconButton(
            tooltip: 'Scan barcode',
            icon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: () => _openBarcode(),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Tap(
              onTap: () => push(context, const AiCoachScreen()),
              child: const Padding(padding: EdgeInsets.all(6), child: MansiAvatar(size: 32)),
            ),
          ),
        ],
      ),
      body: Column(children: [
        _DateStrip(selected: _date, onSelected: _selectDate),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: () async {
              _loadGoal();
              await _load(silent: _data != null);
            },
            child: _body(),
          ),
        ),
      ]),
    );
  }

  Widget _body() {
    if (_loading) return const _FuelSkeleton();
    if (_error != null || _data == null) {
      return ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
        const SizedBox(height: 40),
        ErrorView(error: _error ?? 'error', onRetry: _load),
      ]);
    }
    final d = _data!;
    List<MealLog> items(String id) {
      final list = switch (id) {
        'breakfast' => d.breakfast,
        'lunch' => d.lunch,
        'snacks' => d.snacks,
        _ => d.dinner,
      };
      return list.where((m) => !_removed.contains(m.id)).toList();
    }

    final count = _meals.fold<int>(0, (s, m) => s + items(m.id).length);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _CalorieHero(
          data: d,
          isToday: _isToday,
          date: _date,
          hasGoal: _goal != null || d.targetsSource != 'default',
          onEditGoal: _openGoal,
          unavailableItems: _unavailableItems,
        ),
        const SizedBox(height: 14),
        _WaterCard(
          glasses: _water ?? d.waterGlasses,
          target: d.waterTarget,
          busy: _waterBusy,
          onAdd: () => _addWater(1),
          onRemove: (_water ?? d.waterGlasses) > 0 ? () => _addWater(-1) : null,
        ),
        if (_goalKnown && _goal == null) ...[
          const SizedBox(height: 14),
          PhotoBanner(
            image: AppImages.running,
            eyebrow: 'Personalise your targets',
            title: 'Set your fitness goal',
            subtitle: 'You are seeing default targets. Tell us your goal for calories made for you.',
            cta: 'Set goal',
            height: 160,
            onTap: _openGoal,
          ),
        ],
        if (d.nudges.isNotEmpty) ...[
          const SizedBox(height: 14),
          for (final (i, n) in d.nudges.take(3).indexed) ...[
            if (i > 0) const SizedBox(height: 10),
            _TipCard(text: n),
          ],
        ],
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: _QuickAction(
              icon: Icons.auto_awesome_rounded,
              title: 'Snap a meal',
              subtitle: 'AI reads your plate',
              color: AppColors.purple,
              onTap: () => _openAiScanner(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _QuickAction(
              icon: Icons.qr_code_scanner_rounded,
              title: 'Scan barcode',
              subtitle: 'Packaged foods',
              color: AppColors.blue,
              onTap: () => _openBarcode(),
            ),
          ),
        ]),
        SectionTitle(
          _isToday ? "Today's meals" : 'Meals on ${formatDayDate(_date)}',
          subtitle: count == 0 ? 'Nothing logged yet — start with ADD' : '$count item${count == 1 ? '' : 's'} logged · swipe left to remove',
        ),
        for (final m in _meals) ...[
          _MealCard(
            meal: m,
            items: items(m.id),
            extras: _extras,
            onAdd: () => _openAddFood(m.id),
            confirmDelete: _confirmDelete,
            onDeleted: _onDeleted,
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Date strip
// ---------------------------------------------------------------------------

class _DateStrip extends StatelessWidget {
  const _DateStrip({required this.selected, required this.onSelected});
  final DateTime selected;
  final ValueChanged<DateTime> onSelected;

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final today = _day(DateTime.now());
    final days = [for (var i = 6; i >= 0; i--) _day(today.subtract(Duration(days: i)))];
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
      child: Row(children: [
        for (final d in days)
          Expanded(
            child: Tap(
              onTap: () => onSelected(d),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: d == selected ? AppColors.primary : AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: d == selected ? AppShadows.glow(AppColors.primary) : null,
                ),
                child: Column(children: [
                  Text(d == today ? 'Today' : _wd[d.weekday - 1],
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: d == selected ? Colors.white.withValues(alpha: 0.9) : AppColors.text3)),
                  const SizedBox(height: 4),
                  Text('${d.day}',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: d == selected ? Colors.white : AppColors.text)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero: calorie ring + macros
// ---------------------------------------------------------------------------

class _CalorieHero extends StatelessWidget {
  const _CalorieHero({
    required this.data,
    required this.isToday,
    required this.date,
    required this.hasGoal,
    required this.onEditGoal,
    this.unavailableItems = 0,
  });
  final MealDailySummary data;
  final bool isToday;
  final DateTime date;
  final bool hasGoal;
  final VoidCallback onEditGoal;
  final int unavailableItems;

  @override
  Widget build(BuildContext context) {
    final target = data.calorieTarget;
    final hasTarget = target > 0;
    final eaten = data.totalCalories;
    final remaining = hasTarget ? target - eaten : 0;
    final progress = target > 0 ? eaten / target : 0.0;
    final over = remaining < 0;

    return AppCard(
      padding: const EdgeInsets.all(18),
      radius: 22,
      child: Column(children: [
        Row(children: [
          Expanded(
            child: Text(isToday ? 'Today' : formatDayDate(date),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.text2)),
          ),
          Tap(
            onTap: onEditGoal,
            child: Row(children: [
              Icon(hasGoal ? Icons.tune_rounded : Icons.flag_rounded, size: 16, color: AppColors.primary),
              const SizedBox(width: 4),
              Text(hasGoal ? 'Edit goal' : 'Set goal',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.primary)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          SizedBox(
            width: 148,
            height: 148,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => CustomPaint(
                painter: _RingPainter(progress: v, over: over),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(hasTarget ? formatNumber(remaining.abs()) : formatNumber(eaten),
                        style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1,
                            color: over ? AppColors.red : AppColors.text)),
                    Text(!hasTarget ? 'kcal eaten' : over ? 'kcal over' : 'kcal left',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.text2)),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _stat(Icons.restaurant_rounded, AppColors.primary, 'Eaten', '$eaten kcal'),
              const SizedBox(height: 14),
              _stat(Icons.flag_rounded, AppColors.green,
                  data.targetsSource == 'custom'
                      ? 'Custom target'
                      : data.targetsSource == 'default'
                          ? 'Default target'
                          : 'Daily target',
                  hasTarget ? '$target kcal' : '--'),
              if (data.calorieBalance.isNotEmpty && !data.calorieBalance.contains('NaN')) ...[
                const SizedBox(height: 14),
                Tag(data.calorieBalance,
                    color: over ? AppColors.red : AppColors.green,
                    icon: over ? Icons.trending_up_rounded : Icons.trending_down_rounded),
              ],
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        const Divider(),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _MacroBar('Protein', data.totalProteinG, data.proteinTarget, AppColors.blue)),
          const SizedBox(width: 14),
          Expanded(child: _MacroBar('Carbs', data.totalCarbsG, data.carbsTarget, AppColors.amber)),
          const SizedBox(width: 14),
          Expanded(child: _MacroBar('Fat', data.totalFatG, data.fatTarget, AppColors.pink)),
        ]),
        if (unavailableItems > 0) ...[
          const SizedBox(height: 12),
          Row(children: [
            const Icon(Icons.info_outline_rounded, size: 15, color: AppColors.text3),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Some values unavailable for $unavailableItems item${unavailableItems == 1 ? '' : 's'} '
                '— totals count only the known values.',
                style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _stat(IconData icon, Color color, String label, String value) => Row(children: [
        IconBubble(icon, color: color, size: 34, iconSize: 17),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
            Text(value, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
          ]),
        ),
      ]);
}

class _WaterCard extends StatelessWidget {
  const _WaterCard({
    required this.glasses,
    required this.target,
    required this.busy,
    required this.onAdd,
    required this.onRemove,
  });
  final int glasses;
  final int target;
  final bool busy;
  final VoidCallback onAdd;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final shown = math.max(1, math.min(target, 12));
    final filled = target > 0 ? ((glasses / target).clamp(0.0, 1.0) * shown).round() : 0;
    final done = target > 0 && glasses >= target;
    Widget btn(IconData icon, VoidCallback? onTap, {bool primary = false}) => Tap(
          onTap: busy ? null : onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: primary && onTap != null ? AppColors.blue : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon,
                size: 20,
                color: primary && onTap != null ? Colors.white : (onTap == null ? AppColors.text3 : AppColors.text)),
          ),
        );
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      child: Row(children: [
        IconBubble(Icons.water_drop_rounded, color: AppColors.blue, size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(TextSpan(children: [
              TextSpan(text: '$glasses', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              TextSpan(
                  text: ' / $target glasses',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text3, fontWeight: FontWeight.w700)),
            ])),
            const SizedBox(height: 6),
            Row(children: [
              for (var i = 0; i < shown; i++)
                Expanded(
                  child: Container(
                    height: 6,
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(
                      color: i < filled ? AppColors.blue : AppColors.blueSoft,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 4),
            Text(done ? 'Water goal done' : 'Tap + after each glass (~250 ml)',
                style: TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w600, color: done ? AppColors.green : AppColors.text3)),
          ]),
        ),
        const SizedBox(width: 10),
        btn(Icons.remove_rounded, onRemove),
        const SizedBox(width: 8),
        btn(Icons.add_rounded, onAdd, primary: true),
      ]),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.over});
  final double progress;
  final bool over;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 14.0;
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2);
    final track = Paint()
      ..color = AppColors.surfaceAlt
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(arcRect, 0, math.pi * 2, false, track);

    final sweep = math.pi * 2 * progress.clamp(0.0, 1.0);
    if (sweep <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: over
            ? const [AppColors.red, Color(0xFFFF7A8A), AppColors.red]
            : const [Color(0xFFFFA41B), AppColors.primary, Color(0xFFFFA41B)],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);
    canvas.drawArc(arcRect, -math.pi / 2, sweep, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress || old.over != over;
}

class _MacroBar extends StatelessWidget {
  const _MacroBar(this.label, this.value, this.target, this.color);
  final String label;
  final double value;
  final int target;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = target > 0 ? (value / target).clamp(0.0, 1.0) : 0.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.text2)),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: p),
          duration: const Duration(milliseconds: 800),
          curve: Curves.easeOutCubic,
          builder: (_, v, _) => LinearProgressIndicator(
            value: v,
            minHeight: 7,
            backgroundColor: color.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text.rich(TextSpan(children: [
        TextSpan(text: '${value.round()}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
        TextSpan(
            text: ' / ${target}g',
            style: const TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
      ])),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Tips, quick actions
// ---------------------------------------------------------------------------

class _TipCard extends StatelessWidget {
  const _TipCard({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final good = text.toLowerCase().contains('great');
    final color = good ? AppColors.green : AppColors.amber;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: good ? AppColors.greenSoft : AppColors.amberSoft,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        Text(good ? '🎉' : '💡', style: const TextStyle(fontSize: 22)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text,
              style: const TextStyle(fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600, color: AppColors.text)),
        ),
      ]),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      radius: 18,
      child: Row(children: [
        IconBubble(icon, color: color, size: 40),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w500)),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Meal card
// ---------------------------------------------------------------------------

class _MealCard extends StatelessWidget {
  const _MealCard({
    required this.meal,
    required this.items,
    required this.extras,
    required this.onAdd,
    required this.confirmDelete,
    required this.onDeleted,
  });
  final _Meal meal;
  final List<MealLog> items;
  final Map<String, MealLogExtra> extras;
  final VoidCallback onAdd;
  final Future<bool> Function(MealLog) confirmDelete;
  final ValueChanged<MealLog> onDeleted;

  @override
  Widget build(BuildContext context) {
    final kcal = items.fold<int>(0, (s, i) => s + i.calories);
    return AppCard(
      padding: EdgeInsets.zero,
      radius: 20,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [meal.soft, meal.color.withValues(alpha: 0.22)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(meal.emoji, style: const TextStyle(fontSize: 26)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(meal.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
                const SizedBox(height: 2),
                Text(
                  items.isEmpty ? 'Suggested ${meal.hint}' : '$kcal kcal · ${items.length} item${items.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600),
                ),
              ]),
            ),
            Tap(
              onTap: onAdd,
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: AppColors.greenSoft,
                  border: Border.all(color: AppColors.green),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.add_rounded, size: 18, color: AppColors.green),
                  SizedBox(width: 2),
                  Text('ADD', style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: 13)),
                ]),
              ),
            ),
          ]),
        ),
        if (items.isNotEmpty) ...[
          const Divider(height: 1),
          for (final (i, m) in items.indexed) ...[
            if (i > 0) const Divider(height: 1, indent: 14, endIndent: 14),
            _LoggedRow(
              item: m,
              extra: extras[m.id],
              confirmDelete: confirmDelete,
              onDeleted: onDeleted,
              last: i == items.length - 1,
            ),
          ],
        ],
      ]),
    );
  }
}

class _LoggedRow extends StatelessWidget {
  const _LoggedRow({
    required this.item,
    this.extra,
    required this.confirmDelete,
    required this.onDeleted,
    required this.last,
  });
  final MealLog item;
  final MealLogExtra? extra;
  final Future<bool> Function(MealLog) confirmDelete;
  final ValueChanged<MealLog> onDeleted;
  final bool last;

  String _qty() {
    final e = extra;
    final q = e?.quantity;
    if (e != null && q != null && e.unit == 'g') return '${formatNumber(q)} g';
    if (e != null && q != null && e.unit == 'serving') {
      final unit = e.servingUnit ?? 'serving';
      return q == 1 ? unit : '${formatNumber(q)} × $unit';
    }
    return '${formatNumber(item.servings)} serving';
  }

  /// "—" for a nutrient the food database doesn't have (never a misleading 0).
  String _g(String key, double v) => extra?.unavailable.contains(key) == true ? '—' : '${formatNumber(v)}g';

  @override
  Widget build(BuildContext context) {
    final radius = last ? const BorderRadius.vertical(bottom: Radius.circular(20)) : BorderRadius.zero;
    final noKcal = extra?.unavailable.contains('calories') == true;
    return ClipRRect(
      borderRadius: radius,
      child: Dismissible(
        key: ValueKey('meal-${item.id}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: (_) => confirmDelete(item),
        onDismissed: (_) => onDeleted(item),
        background: Container(
          color: AppColors.red,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 22),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.delete_outline_rounded, color: Colors.white),
            SizedBox(width: 6),
            Text('Remove', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          ]),
        ),
        child: Container(
          color: AppColors.surface,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
              child: Text(foodEmoji('', item.foodName), style: const TextStyle(fontSize: 18)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.foodName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 2),
                Text(
                  '${_qty()} · P ${_g('proteinG', item.proteinG)} · C ${_g('carbsG', item.carbsG)} · F ${_g('fatG', item.fatG)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w500),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            Text(noKcal ? '—' : '${item.calories}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const Text(' kcal', style: TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Skeleton
// ---------------------------------------------------------------------------

class _FuelSkeleton extends StatelessWidget {
  const _FuelSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        Shimmer(
          child: Column(children: [
            Container(
              height: 280,
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(22)),
              padding: const EdgeInsets.all(18),
              child: const Row(children: [
                SkeletonBox(height: 148, width: 148, radius: 74),
                SizedBox(width: 18),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SkeletonBox(height: 14, width: 90),
                    SizedBox(height: 10),
                    SkeletonBox(height: 18, width: 120),
                    SizedBox(height: 20),
                    SkeletonBox(height: 14, width: 90),
                    SizedBox(height: 10),
                    SkeletonBox(height: 18, width: 120),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            const SkeletonBox(height: 56, radius: 18),
            const SizedBox(height: 14),
            const Row(children: [
              Expanded(child: SkeletonBox(height: 68, radius: 18)),
              SizedBox(width: 12),
              Expanded(child: SkeletonBox(height: 68, radius: 18)),
            ]),
            const SizedBox(height: 28),
            for (var i = 0; i < 4; i++) ...[
              const SkeletonBox(height: 80, radius: 20),
              const SizedBox(height: 14),
            ],
          ]),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Add-food sheet: search the encyclopedia, or jump to a scanner
// ---------------------------------------------------------------------------

enum _AddResult { logged, ai, barcode }

class _AddFoodSheet extends StatefulWidget {
  const _AddFoodSheet({required this.mealType, required this.date});
  final String mealType;
  final DateTime? date;

  @override
  State<_AddFoodSheet> createState() => _AddFoodSheetState();
}

class _AddFoodSheetState extends State<_AddFoodSheet> {
  static const _all = 'All';
  static const _pageSize = 30;
  static const _diets = [_all, 'veg', 'egg', 'nonveg'];

  final _search = TextEditingController();
  Timer? _debounce;
  String _category = _all;
  String _diet = _all;
  List<FoodCategory> _categories = const [];
  final List<DbFood> _foods = [];
  bool _ready = false;
  String? _credit;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  Object? _error;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _reload(initial: true);
    _loadCategories();
  }

  Future<FoodSearchPage> _page(int offset) {
    final q = _search.text.trim();
    return context.read<Session>().api.searchFoods(
          q: q.isEmpty ? null : q,
          category: _category == _all ? null : _category,
          diet: _diet == _all ? null : _diet,
          limit: _pageSize,
          offset: offset,
        );
  }

  Future<void> _reload({bool initial = false}) async {
    final id = ++_req;
    if (!initial) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final page = await _page(0);
      if (!mounted || id != _req) return;
      setState(() {
        _foods
          ..clear()
          ..addAll(page.foods);
        _hasMore = page.hasMore;
        _ready = page.ready;
        _credit = page.credit;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _req) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _more() async {
    if (_loadingMore || !_hasMore || _loading) return;
    final id = _req;
    setState(() => _loadingMore = true);
    try {
      // Packaged foods are only appended to the first page, so page by database foods.
      final page = await _page(_ready ? _foods.where((f) => f.isDb).length : _foods.length);
      if (!mounted || id != _req) return;
      setState(() {
        _foods.addAll(page.foods.where((f) => !_foods.any((x) => x.id == f.id)));
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || id != _req) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
      toast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await context.read<Session>().api.foodCategories(diet: _diet == _all ? null : _diet);
      if (!mounted) return;
      setState(() => _categories = cats);
    } catch (_) {
      // Category chips are optional — search still works without them.
    }
  }

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _reload();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _pick(DbFood f) async {
    final logged = f.isDb
        ? await _showDbFoodLogSheet(context, f, mealType: widget.mealType, date: widget.date, credit: _credit)
        : await showFoodLogSheet(context, f.toFoodItem(), mealType: widget.mealType, date: widget.date);
    if (logged && mounted) Navigator.pop(context, _AddResult.logged);
  }

  List<String> get _categoryOptions {
    final seen = <String>{};
    return [_all, for (final c in _categories) if (seen.add(c.name)) c.name];
  }

  bool _isRawCategory(String name) => _categories.any((c) => c.name == name && c.type == 'raw') &&
      !_categories.any((c) => c.name == name && c.type == 'cooked');

  @override
  Widget build(BuildContext context) {
    final meal = _mealOf(widget.mealType);
    return FractionallySizedBox(
      heightFactor: 0.92,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Row(children: [
            Text(meal.emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Add to ${meal.label}',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                Text(widget.date == null ? 'Logging for today' : 'Logging for ${formatDayDate(widget.date!)}',
                    style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: _ScanTile(
                icon: Icons.auto_awesome_rounded,
                label: 'Scan meal with AI',
                color: AppColors.purple,
                onTap: () => Navigator.pop(context, _AddResult.ai),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ScanTile(
                icon: Icons.qr_code_scanner_rounded,
                label: 'Scan barcode',
                color: AppColors.blue,
                onTap: () => Navigator.pop(context, _AddResult.barcode),
              ),
            ),
          ]),
        ),
        if (widget.date != null)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('Scanned meals are logged to today.',
                style: TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: RotatingSearchBar(
            hints: const ["'roti'", "'dal tadka'", "'paneer'", "'idli'", "'ande ka sandwich'", "'poha'"],
            controller: _search,
            onChanged: _onSearch,
            onSubmitted: (_) {
              _debounce?.cancel();
              _reload();
            },
          ),
        ),
        if (_ready) ...[
          const SizedBox(height: 12),
          ChoiceChips<String>(
            options: _diets,
            selected: _diet,
            label: (d) => switch (d) { 'veg' => 'Veg', 'egg' => 'Egg', 'nonveg' => 'Non-veg', _ => 'All diets' },
            icon: (d) => d == _all ? Icons.restaurant_menu_rounded : Icons.circle,
            onSelected: (d) {
              setState(() => _diet = d);
              _loadCategories();
              _reload();
            },
          ),
          if (_categoryOptions.length > 1) ...[
            const SizedBox(height: 8),
            ChoiceChips<String>(
              options: _categoryOptions,
              selected: _category,
              label: (c) => c,
              icon: (c) => c == _all ? null : (_isRawCategory(c) ? Icons.eco_rounded : Icons.restaurant_rounded),
              onSelected: (c) {
                setState(() => _category = c);
                _reload();
              },
            ),
          ],
          if (_diet == 'veg')
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Veg tags are based on dish names — check ingredients if you follow a strict diet.',
                  style: TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
            ),
        ],
        const SizedBox(height: 6),
        Expanded(child: _list()),
      ]),
    );
  }

  Widget _list() {
    if (_loading) return const SkeletonList(count: 5, itemHeight: 56);
    if (_error != null) return ErrorView(error: _error!, onRetry: _reload);
    if (_foods.isEmpty) {
      return SingleChildScrollView(
        child: EmptyView(
          icon: Icons.search_off_rounded,
          title: 'No foods found',
          message: _diet != _all || _category != _all
              ? 'Try another spelling, or clear the filters.'
              : 'Try "roti", "dal" or "paneer" — or scan the meal with AI instead.',
          action: SizedBox(
            width: 200,
            child: _diet != _all || _category != _all
                ? OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _diet = _all;
                        _category = _all;
                      });
                      _loadCategories();
                      _reload();
                    },
                    icon: const Icon(Icons.filter_alt_off_rounded),
                    label: const Text('Clear filters'),
                  )
                : OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context, _AddResult.ai),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: const Text('Scan with AI'),
                  ),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _foods.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 20),
      itemBuilder: (_, i) {
        if (i < _foods.length) return _DbFoodRow(food: _foods[i], onAdd: () => _pick(_foods[i]));
        if (_hasMore) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _more();
          });
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))),
          );
        }
        return _credit == null ? const SizedBox.shrink() : _CreditLine(_credit!);
      },
    );
  }
}

/// Source credit for the Indian food database (licence: see the BRD PDF).
class _CreditLine extends StatelessWidget {
  const _CreditLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        const Icon(Icons.menu_book_rounded, size: 14, color: AppColors.text3),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

/// Indian food-label style diet mark: green (veg), amber (egg), red (non-veg).
class _DietMark extends StatelessWidget {
  const _DietMark(this.diet, {this.size = 14});
  final String? diet;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = switch (diet) { 'veg' => AppColors.green, 'egg' => AppColors.amber, 'nonveg' => AppColors.red, _ => null };
    if (color == null) return const SizedBox.shrink();
    return Tooltip(
      message: switch (diet) { 'veg' => 'Veg', 'egg' => 'Contains egg', _ => 'Non-veg' },
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.2),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: color, width: 1.4),
          borderRadius: BorderRadius.circular(3),
        ),
        child: DecoratedBox(decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      ),
    );
  }
}

String _fmtG(double? v) => v == null ? '—' : '${formatNumber((v * 10).round() / 10)}g';
String _fmtKcal(double? v) => v == null ? '—' : '${v.round()}';

String _servingLabel(DbFood f) {
  final w = f.servingWeightG;
  final unit = f.servingUnit;
  if (w == null || unit.toLowerCase().replaceAll(' ', '') == '100g') return unit;
  return '$unit (${formatNumber(w.round())} g)';
}

class _DbFoodRow extends StatelessWidget {
  const _DbFoodRow({required this.food, required this.onAdd});
  final DbFood food;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final s = food.perServing;
    return Tap(
      onTap: onAdd,
      scale: 0.99,
      child: Row(children: [
        Stack(clipBehavior: Clip.none, children: [
          Container(
            width: 54,
            height: 54,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(16)),
            child: Text(foodEmoji(food.category, food.name), style: const TextStyle(fontSize: 26)),
          ),
          if (food.diet != null) Positioned(right: -3, bottom: -3, child: _DietMark(food.diet)),
        ]),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(food.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, height: 1.25)),
            if (food.localName != null && food.localName!.isNotEmpty)
              Text(food.localName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(
              '${_servingLabel(food)} · ${_fmtKcal(s.calories)} kcal${food.type == 'raw' ? ' · Raw' : food.type == 'packaged' ? ' · Packaged' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [
              Tag('P ${_fmtG(s.proteinG)}', color: AppColors.blue, dense: true),
              Tag('C ${_fmtG(s.carbsG)}', color: AppColors.amber, dense: true),
              Tag('F ${_fmtG(s.fatG)}', color: AppColors.pink, dense: true),
            ]),
          ]),
        ),
        const SizedBox(width: 10),
        QtyStepper(qty: 0, compact: true, onChanged: (_) => onAdd()),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Log panel for the Indian food database: servings OR grams, meal, live preview
// ---------------------------------------------------------------------------

Future<bool> _showDbFoodLogSheet(
  BuildContext context,
  DbFood food, {
  required String mealType,
  DateTime? date,
  String? credit,
}) async {
  final logged = await showAppSheet<bool>(
    context,
    builder: (_) => _DbFoodLogPanel(food: food, initialMeal: mealType, date: date, credit: credit),
  );
  return logged == true;
}

class _DbFoodLogPanel extends StatefulWidget {
  const _DbFoodLogPanel({required this.food, required this.initialMeal, this.date, this.credit});
  final DbFood food;
  final String initialMeal;
  final DateTime? date;
  final String? credit;

  @override
  State<_DbFoodLogPanel> createState() => _DbFoodLogPanelState();
}

class _DbFoodLogPanelState extends State<_DbFoodLogPanel> {
  bool _grams = false;
  double _servings = 1; // default: 1 Serving Unit
  late final _gramCtrl = TextEditingController(text: '${(widget.food.servingWeightG ?? 100).round()}');
  late String _meal = widget.initialMeal;
  bool _busy = false;
  bool _showMicros = false;

  @override
  void dispose() {
    _gramCtrl.dispose();
    super.dispose();
  }

  double? get _gramValue {
    final v = double.tryParse(_gramCtrl.text.trim().replaceAll(',', '.'));
    return v != null && v >= 1 && v <= 3000 ? v : null;
  }

  double? get _quantity => _grams ? _gramValue : _servings;

  Future<void> _log() async {
    final q = _quantity;
    if (q == null) {
      toast(context, 'Enter grams between 1 and 3000', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final date = widget.date;
      await context.read<Session>().api.logDbFood(
            mealType: _meal,
            foodId: widget.food.id,
            unit: _grams ? 'g' : 'serving',
            quantity: q,
            loggedOn: date != null && _day(date) != _day(DateTime.now()) ? apiDate(date) : null,
          );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      final what = _grams ? '${formatNumber(q)} g' : '${formatNumber(q)} ×';
      toast(context, 'Added $what ${widget.food.name} to ${_mealOf(_meal).label}');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toast(context, friendlyError(e), error: true);
    }
  }

  /// Micronutrients for the chosen quantity (scaled from one serving).
  List<(String, double, String)> _micros() {
    final f = widget.food;
    final q = _quantity;
    if (q == null) return const [];
    double? factor;
    if (!_grams) {
      factor = q;
    } else if (f.servingWeightG != null && f.servingWeightG! > 0) {
      factor = q / f.servingWeightG!;
    }
    if (factor == null) return const [];
    const labels = {
      'ironMg': ('Iron', 'mg'),
      'calciumMg': ('Calcium', 'mg'),
      'magnesiumMg': ('Magnesium', 'mg'),
      'sodiumMg': ('Sodium', 'mg'),
      'potassiumMg': ('Potassium', 'mg'),
      'zincMg': ('Zinc', 'mg'),
      'phosphorusMg': ('Phosphorus', 'mg'),
      'vitaminAUg': ('Vitamin A', 'µg'),
      'vitaminCMg': ('Vitamin C', 'mg'),
      'vitaminDUg': ('Vitamin D', 'µg'),
      'vitaminB12Ug': ('Vitamin B12', 'µg'),
      'folateUg': ('Folate', 'µg'),
      'sugarG': ('Sugar', 'g'),
      'saturatedFatG': ('Saturated fat', 'g'),
      'cholesterolMg': ('Cholesterol', 'mg'),
    };
    return [
      for (final e in labels.entries)
        if (f.microsServing[e.key] != null) (e.value.$1, f.microsServing[e.key]! * factor, e.value.$2),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.food;
    final q = _quantity;
    final n = q == null ? const FoodNutrients() : f.nutrientsFor(grams: _grams, quantity: q);
    final missing = q != null && [n.calories, n.proteinG, n.carbsG, n.fatG].any((v) => v == null);
    final micros = _micros();
    final kcal = n.calories;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [AppColors.primarySoft, AppColors.amberSoft]),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(foodEmoji(f.category, f.name), style: const TextStyle(fontSize: 32)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(f.name,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3, height: 1.2)),
              if (f.localName != null && f.localName!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(f.localName!,
                    style: const TextStyle(fontSize: 12.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (f.diet != null) _DietMark(f.diet, size: 16),
                Tag(f.type == 'raw' ? 'Raw ingredient' : 'Cooked dish', color: AppColors.teal, dense: true),
                Tag(f.category, color: AppColors.text2, dense: true),
              ]),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Text('1 serving = ${_servingLabel(f)}'
            '${f.per100g?.calories != null ? ' · ${f.per100g!.calories!.round()} kcal per 100 g' : ''}',
            style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Row(children: [
          _modeTab('Servings', !_grams, () => setState(() => _grams = false)),
          const SizedBox(width: 8),
          _modeTab('Grams', _grams, f.gramsAvailable ? () => setState(() => _grams = true) : null),
        ]),
        const SizedBox(height: 14),
        if (!_grams)
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Servings', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                Text(f.servingUnit,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
              ]),
            ),
            _ServingStepper(value: _servings, onChanged: (v) => setState(() => _servings = v)),
          ])
        else ...[
          TextField(
            controller: _gramCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Amount',
              suffixText: 'g',
              errorText: _gramValue == null ? 'Enter 1 – 3000 g' : null,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final g in {50, 100, 150, 200, if (f.servingWeightG != null) f.servingWeightG!.round()})
              Tap(
                onTap: () => setState(() => _gramCtrl.text = '$g'),
                child: Tag('$g g', color: _gramValue == g ? AppColors.primary : AppColors.text2),
              ),
          ]),
        ],
        if (!f.gramsAvailable)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Grams are not available for this food — log it in servings.',
                style: TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 18),
        const Text('Add to', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 10),
        _MealPicker(selected: _meal, onChanged: (m) => setState(() => _meal = m)),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(18)),
          child: Row(children: [
            _preview(_fmtKcal(n.calories), 'kcal', AppColors.primary),
            _preview(n.proteinG == null ? '—' : formatNumber((n.proteinG! * 10).round() / 10), 'protein g', AppColors.blue),
            _preview(n.carbsG == null ? '—' : formatNumber((n.carbsG! * 10).round() / 10), 'carbs g', AppColors.amber),
            _preview(n.fatG == null ? '—' : formatNumber((n.fatG! * 10).round() / 10), 'fat g', AppColors.pink),
          ]),
        ),
        if (missing)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('— = not available in the source data (not counted as zero).',
                style: TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
          ),
        if (micros.isNotEmpty || n.fibreG != null) ...[
          const SizedBox(height: 8),
          Tap(
            onTap: () => setState(() => _showMicros = !_showMicros),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                const Text('Fibre, vitamins & minerals', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
                const Spacer(),
                Icon(_showMicros ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: AppColors.text2),
              ]),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _showMicros ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Wrap(spacing: 8, runSpacing: 8, children: [
              if (n.fibreG != null) Tag('Fibre ${_fmtG(n.fibreG)}', color: AppColors.teal),
              for (final m in micros)
                Tag('${m.$1} ${formatNumber(m.$2 >= 10 ? m.$2.round() : (m.$2 * 10).round() / 10)}${m.$3}',
                    color: AppColors.teal),
            ]),
          ),
        ],
        if (widget.credit != null) _CreditLine(widget.credit!),
        const SizedBox(height: 12),
        AppButton(
          label: kcal == null ? 'Add to ${_mealOf(_meal).label}' : 'Add ${kcal.round()} kcal to ${_mealOf(_meal).label}',
          icon: Icons.add_task_rounded,
          busy: _busy,
          onPressed: q == null ? null : _log,
        ),
      ]),
    );
  }

  Widget _modeTab(String label, bool selected, VoidCallback? onTap) => Expanded(
        child: Tap(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? AppColors.primarySoft : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: selected ? AppColors.primary : AppColors.line, width: selected ? 1.6 : 1),
            ),
            child: Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                    color: onTap == null ? AppColors.text3 : (selected ? AppColors.primary : AppColors.text2))),
          ),
        ),
      );

  Widget _preview(String value, String label, Color color) => Expanded(
        child: Column(children: [
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color, letterSpacing: -0.4)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.text2, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _MealPicker extends StatelessWidget {
  const _MealPicker({required this.selected, required this.onChanged});
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (final (i, m) in _meals.indexed) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(
          child: Tap(
            onTap: () => onChanged(m.id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: selected == m.id ? m.soft : AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: selected == m.id ? m.color : AppColors.line, width: selected == m.id ? 1.6 : 1),
              ),
              child: Column(children: [
                Text(m.emoji, style: const TextStyle(fontSize: 20)),
                const SizedBox(height: 4),
                Text(m.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w800, color: selected == m.id ? m.color : AppColors.text2)),
              ]),
            ),
          ),
        ),
      ],
    ]);
  }
}

class _ScanTile extends StatelessWidget {
  const _ScanTile({required this.icon, required this.label, required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: color)),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Log panel: servings, meal and live macro preview
// ---------------------------------------------------------------------------

class _FoodLogPanel extends StatefulWidget {
  const _FoodLogPanel({required this.food, required this.initialMeal, this.date, this.eyebrow});
  final FoodItem food;
  final String initialMeal;
  final DateTime? date;
  final String? eyebrow;

  @override
  State<_FoodLogPanel> createState() => _FoodLogPanelState();
}

class _FoodLogPanelState extends State<_FoodLogPanel> {
  double _servings = 1;
  late String _meal = widget.initialMeal;
  bool _busy = false;
  bool _showMicros = false;

  double _r1(double v) => (v * 10).round() / 10;

  Future<void> _log() async {
    final f = widget.food;
    setState(() => _busy = true);
    try {
      final date = widget.date;
      await context.read<Session>().api.logMeal({
        'mealType': _meal,
        if (f.id.isNotEmpty) 'foodId': f.id,
        'foodName': f.name,
        'servings': _servings,
        'calories': (f.calories * _servings).round(),
        'proteinG': _r1(f.proteinG * _servings),
        'carbsG': _r1(f.carbsG * _servings),
        'fatG': _r1(f.fatG * _servings),
        if (date != null && _day(date) != _day(DateTime.now())) 'loggedOn': apiDate(date),
      });
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      toast(context, 'Added ${formatNumber(_servings)} × ${f.name} to ${_mealOf(_meal).label}');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.food;
    final s = _servings;
    final micros = [
      ('Fibre', f.fibreG, 'g'),
      ('Iron', f.ironMg, 'mg'),
      ('Calcium', f.calciumMg, 'mg'),
      ('Magnesium', f.magnesiumMg, 'mg'),
      ('Sodium', f.sodiumMg, 'mg'),
    ].where((m) => m.$2 > 0).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [AppColors.primarySoft, AppColors.amberSoft]),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(foodEmoji(f.category, f.name), style: const TextStyle(fontSize: 32)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (widget.eyebrow != null) ...[
                Tag(widget.eyebrow!, color: AppColors.green, icon: Icons.check_circle_rounded, dense: true),
                const SizedBox(height: 6),
              ],
              Text(f.name,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3, height: 1.2)),
              const SizedBox(height: 4),
              Text('${f.servingUnit} · ${f.category}',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
        const SizedBox(height: 20),
        Row(children: [
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Servings', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              Text('Half-serving steps', style: TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
            ]),
          ),
          _ServingStepper(
            value: s,
            onChanged: (v) => setState(() => _servings = v),
          ),
        ]),
        const SizedBox(height: 18),
        const Text('Add to', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 10),
        Row(children: [
          for (final (i, m) in _meals.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Tap(
                onTap: () => setState(() => _meal = m.id),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: _meal == m.id ? m.soft : AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _meal == m.id ? m.color : AppColors.line, width: _meal == m.id ? 1.6 : 1),
                  ),
                  child: Column(children: [
                    Text(m.emoji, style: const TextStyle(fontSize: 20)),
                    const SizedBox(height: 4),
                    Text(m.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: _meal == m.id ? m.color : AppColors.text2)),
                  ]),
                ),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(18)),
          child: Row(children: [
            _preview('${(f.calories * s).round()}', 'kcal', AppColors.primary),
            _preview(formatNumber(_r1(f.proteinG * s)), 'protein g', AppColors.blue),
            _preview(formatNumber(_r1(f.carbsG * s)), 'carbs g', AppColors.amber),
            _preview(formatNumber(_r1(f.fatG * s)), 'fat g', AppColors.pink),
          ]),
        ),
        if (micros.isNotEmpty) ...[
          const SizedBox(height: 8),
          Tap(
            onTap: () => setState(() => _showMicros = !_showMicros),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                const Text('Micronutrients', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
                const Spacer(),
                Icon(_showMicros ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: AppColors.text2),
              ]),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _showMicros ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in micros)
                Tag('${m.$1} ${formatNumber(_r1(m.$2 * s))}${m.$3}', color: AppColors.teal),
            ]),
          ),
        ],
        if (f.educationalNotes != null && f.educationalNotes!.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(14)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('📘', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(f.educationalNotes!,
                    style: const TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.text, fontWeight: FontWeight.w500)),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 20),
        AppButton(
          label: 'Add ${(f.calories * s).round()} kcal to ${_mealOf(_meal).label}',
          icon: Icons.add_task_rounded,
          busy: _busy,
          onPressed: _log,
        ),
      ]),
    );
  }

  Widget _preview(String value, String label, Color color) => Expanded(
        child: Column(children: [
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color, letterSpacing: -0.4)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.text2, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _ServingStepper extends StatelessWidget {
  const _ServingStepper({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i, double? next) => InkResponse(
          onTap: next == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onChanged(next);
                },
          radius: 20,
          child: SizedBox(
            width: 40,
            height: 42,
            child: Icon(i, color: next == null ? Colors.white.withValues(alpha: 0.4) : Colors.white, size: 20),
          ),
        );
    return Container(
      decoration: BoxDecoration(color: AppColors.green, borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        btn(Icons.remove_rounded, value > 0.5 ? value - 0.5 : null),
        SizedBox(
          width: 44,
          child: Text('${formatNumber(value)}×',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
        ),
        btn(Icons.add_rounded, value < 10 ? value + 0.5 : null),
      ]),
    );
  }
}
