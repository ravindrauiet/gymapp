import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';

/// Goal-based onboarding: goal → body stats → activity → personalised targets.
///
/// When [isEditing] is false this is the last step of first-run onboarding
/// (pushed after profile setup); finishing or skipping returns to the app root.
class GoalSelectionScreen extends StatefulWidget {
  const GoalSelectionScreen({super.key, this.isEditing = false});

  final bool isEditing;

  @override
  State<GoalSelectionScreen> createState() => _GoalSelectionScreenState();
}

class _GoalOption {
  const _GoalOption(this.id, this.title, this.subtitle, this.hindi, this.image, this.icon, this.color);
  final String id;
  final String title;
  final String subtitle;
  final String hindi;
  final String image;
  final IconData icon;
  final Color color;
}

const _goals = [
  _GoalOption('weight_loss', 'Lose weight', 'A gentle calorie deficit to burn fat steadily', 'Patla hona hai',
      AppImages.running, Icons.trending_down_rounded, AppColors.primary),
  _GoalOption('muscle_gain', 'Build muscle', 'A calorie surplus with high protein to bulk up', 'Bulk karna hai',
      AppImages.strength, Icons.fitness_center_rounded, AppColors.blue),
  _GoalOption('maintenance', 'Stay fit', 'Balanced calories to keep your current shape', 'Jaisa hoon waisa',
      AppImages.yoga, Icons.self_improvement_rounded, AppColors.purple),
];

class _Activity {
  const _Activity(this.id, this.title, this.subtitle, this.emoji, this.mult);
  final String id;
  final String title;
  final String subtitle;
  final String emoji;
  final double mult;
}

const _activities = [
  _Activity('sedentary', 'Mostly sitting', 'Desk job, little or no exercise', '🪑', 1.2),
  _Activity('light', 'Lightly active', '1–3 workouts a week', '🚶', 1.375),
  _Activity('moderate', 'Moderately active', '3–5 workouts a week', '🏃', 1.55),
  _Activity('very_active', 'Very active', '6–7 intense sessions a week', '🔥', 1.725),
];

class _GoalSelectionScreenState extends State<GoalSelectionScreen> {
  final _pages = PageController();
  int _step = 0;

  String _goal = 'weight_loss';
  String _gender = 'male';
  int _age = 26;
  double _height = 170;
  double _weight = 72;
  double _target = 68;
  String _activity = 'moderate';

  bool _loading = true;
  bool _saving = false;
  UserGoal? _saved;
  bool _hadGoal = false;

  @override
  void initState() {
    super.initState();
    final g = context.read<Session>().user?.gender;
    if (g == 'male' || g == 'female' || g == 'other') _gender = g!;
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    try {
      final goal = await context.read<Session>().api.goal();
      if (goal != null && mounted) {
        setState(() {
          _hadGoal = true;
          if (_goals.any((o) => o.id == goal.goalType)) _goal = goal.goalType;
          if (const ['male', 'female', 'other'].contains(goal.gender)) _gender = goal.gender;
          _age = goal.age.clamp(12, 100);
          _height = goal.heightCm.clamp(120, 220).roundToDouble();
          _weight = (goal.currentWeightKg.clamp(30, 200) * 2).round() / 2;
          _target = (goal.targetWeightKg.clamp(30, 200) * 2).round() / 2;
          if (_activities.any((a) => a.id == goal.activityLevel)) _activity = goal.activityLevel;
        });
      }
    } catch (_) {
      // No saved goal / offline — start from sensible defaults.
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Same Mifflin-St Jeor maths the backend uses, for a live preview.
  ({int cals, int protein, int carbs, int fat}) _estimate() {
    var bmr = 10 * _weight + 6.25 * _height - 5 * _age;
    bmr = _gender == 'male' ? bmr + 5 : bmr - 161;
    final tdee = (bmr * _activities.firstWhere((a) => a.id == _activity).mult).round();
    final cals = switch (_goal) {
      'weight_loss' => tdee - 500 < 1200 ? 1200 : tdee - 500,
      'muscle_gain' => tdee + 400,
      _ => tdee,
    };
    final p = (_weight * (_goal == 'muscle_gain' ? 2.0 : _goal == 'weight_loss' ? 1.8 : 1.5)).round();
    final f = ((cals * 0.25) / 9).round();
    final rest = cals - p * 4 - cals * 0.25;
    final c = ((rest < 0 ? 0 : rest) / 4).round();
    return (cals: cals, protein: p, carbs: c, fat: f);
  }

  void _go(int step) {
    FocusScope.of(context).unfocus();
    setState(() => _step = step);
    _pages.animateToPage(step, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final g = await context.read<Session>().api.saveGoal({
        'goalType': _goal,
        'age': _age,
        'gender': _gender,
        'heightCm': _height,
        'currentWeightKg': _weight,
        'targetWeightKg': _target,
        'activityLevel': _activity,
      });
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _saved = g;
        _saving = false;
      });
      _go(3);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast(context, friendlyError(e), error: true);
    }
  }

  void _finish() {
    final nav = Navigator.of(context);
    if (widget.isEditing) {
      nav.pop(_saved != null);
    } else {
      // End of onboarding: drop back to the app root (the home shell).
      nav.popUntil((r) => r.isFirst);
    }
  }

  void _back() {
    if (_step > 0 && _step < 3) {
      _go(_step - 1);
    } else {
      _finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = _step == 3;
    return PopScope(
      canPop: _step == 0 || done,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: done
              ? null
              : IconButton(
                  icon: Icon(_step == 0 ? Icons.close_rounded : Icons.arrow_back_rounded),
                  onPressed: _back,
                ),
          title: Text(done
              ? 'Your plan'
              : widget.isEditing && _hadGoal
                  ? 'Update your goal'
                  : 'Set your goal'),
          actions: [
            if (!widget.isEditing && !done)
              TextButton(onPressed: _finish, child: const Text('Skip', style: TextStyle(color: AppColors.text2))),
          ],
          bottom: done
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(14),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Row(children: [
                      for (var i = 0; i < 3; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            height: 4,
                            decoration: BoxDecoration(
                              color: i <= _step ? AppColors.primary : AppColors.line,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ],
                    ]),
                  ),
                ),
        ),
        body: _loading
            ? const SkeletonList(count: 3, itemHeight: 120)
            : PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                children: [_goalStep(), _statsStep(), _activityStep(), _resultStep()],
              ),
        bottomNavigationBar: _loading ? null : BottomActionBar(child: _cta()),
      ),
    );
  }

  Widget _cta() => switch (_step) {
        0 => AppButton(label: 'Continue', trailing: const Icon(Icons.arrow_forward_rounded, size: 20), onPressed: () => _go(1)),
        1 => AppButton(label: 'Continue', trailing: const Icon(Icons.arrow_forward_rounded, size: 20), onPressed: () => _go(2)),
        2 => AppButton(label: 'Calculate my plan', icon: Icons.auto_awesome_rounded, busy: _saving, onPressed: _save),
        _ => AppButton(
            label: widget.isEditing ? 'Done' : 'Start my journey',
            icon: Icons.check_rounded,
            onPressed: _finish,
          ),
      };

  Widget _heading(String title, String subtitle) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6, height: 1.2)),
          const SizedBox(height: 6),
          Text(subtitle, style: const TextStyle(fontSize: 14, color: AppColors.text2, height: 1.4)),
        ]),
      );

  // ---- Step 1: goal ---------------------------------------------------------

  Widget _goalStep() {
    return RadioGroup<String>(
      groupValue: _goal,
      onChanged: (v) {
        if (v != null) setState(() => _goal = v);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _heading("What's your main goal?", 'We use it to set your daily calories and macros.'),
          for (final g in _goals) ...[
            _GoalCard(option: g, selected: _goal == g.id, onTap: () => setState(() => _goal = g.id)),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }

  // ---- Step 2: body stats ---------------------------------------------------

  Widget _statsStep() {
    final bmi = _weight / ((_height / 100) * (_height / 100));
    final (bmiLabel, bmiColor) = bmi < 18.5
        ? ('Underweight', AppColors.blue)
        : bmi < 25
            ? ('Healthy', AppColors.green)
            : bmi < 30
                ? ('Overweight', AppColors.amber)
                : ('Obese', AppColors.red);
    final diff = _target - _weight;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _heading('Tell us about you', 'Your body stats help us estimate how much energy you burn.'),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Gender', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 12),
            Row(children: [
              for (final (i, g) in const [('male', 'Male', '👨'), ('female', 'Female', '👩'), ('other', 'Other', '🧑')].indexed) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: Tap(
                    onTap: () => setState(() => _gender = g.$1),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: _gender == g.$1 ? AppColors.primarySoft : AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _gender == g.$1 ? AppColors.primary : Colors.transparent, width: 1.6),
                      ),
                      child: Column(children: [
                        Text(g.$3, style: const TextStyle(fontSize: 22)),
                        const SizedBox(height: 4),
                        Text(g.$2,
                            style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                                color: _gender == g.$1 ? AppColors.primary : AppColors.text2)),
                      ]),
                    ),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 20),
            Row(children: [
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Age', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  Text('years', style: TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
                ]),
              ),
              _IntStepper(value: _age, min: 12, max: 100, onChanged: (v) => setState(() => _age = v)),
            ]),
          ]),
        ),
        const SizedBox(height: 14),
        AppCard(
          child: Column(children: [
            _SliderRow(
              label: 'Height',
              value: _height,
              unit: 'cm',
              min: 120,
              max: 220,
              divisions: 100,
              onChanged: (v) => setState(() => _height = v.roundToDouble()),
            ),
            const SizedBox(height: 8),
            _SliderRow(
              label: 'Current weight',
              value: _weight,
              unit: 'kg',
              min: 30,
              max: 200,
              divisions: 340,
              onChanged: (v) => setState(() => _weight = (v * 2).round() / 2),
            ),
            const SizedBox(height: 8),
            _SliderRow(
              label: 'Target weight',
              value: _target,
              unit: 'kg',
              min: 30,
              max: 200,
              divisions: 340,
              color: AppColors.green,
              onChanged: (v) => setState(() => _target = (v * 2).round() / 2),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: AppCard(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Your BMI', style: TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(bmi.toStringAsFixed(1), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Tag(bmiLabel, color: bmiColor, dense: true),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: AppCard(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Change', style: TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('${diff > 0 ? '+' : ''}${_fmt(diff)} kg',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Tag(diff < 0 ? 'To lose' : diff > 0 ? 'To gain' : 'Maintain',
                    color: diff == 0 ? AppColors.purple : AppColors.primary, dense: true),
              ]),
            ),
          ),
        ]),
      ],
    );
  }

  // ---- Step 3: activity -----------------------------------------------------

  Widget _activityStep() {
    final e = _estimate();
    return RadioGroup<String>(
      groupValue: _activity,
      onChanged: (v) {
        if (v != null) setState(() => _activity = v);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _heading('How active are you?', 'Think about a typical week, including workouts and your job.'),
          for (final a in _activities) ...[
            _ActivityCard(activity: a, selected: _activity == a.id, onTap: () => setState(() => _activity = a.id)),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 8),
          AppCard(
            color: AppColors.ink,
            child: Row(children: [
              const Text('⚡', style: TextStyle(fontSize: 26)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Estimated ${e.cals} kcal / day',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text('Protein ${e.protein}g · Carbs ${e.carbs}g · Fat ${e.fat}g',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12.5)),
                ]),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  // ---- Result ---------------------------------------------------------------

  Widget _resultStep() {
    final g = _saved;
    if (g == null) return const SizedBox.shrink();
    final opt = _goals.firstWhere((o) => o.id == g.goalType, orElse: () => _goals.first);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(
            height: 210,
            child: Stack(fit: StackFit.expand, children: [
              Image.asset(opt.image, fit: BoxFit.cover),
              const PhotoScrim(strength: 0.85),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [
                  const Tag('PLAN READY', color: AppColors.green, solid: true, icon: Icons.check_rounded),
                  const SizedBox(height: 10),
                  Text.rich(TextSpan(children: [
                    TextSpan(
                        text: '${g.dailyCalorieTarget}',
                        style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: -1.2)),
                    const TextSpan(text: ' kcal / day', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ]), style: const TextStyle(color: Colors.white)),
                  Text('Goal: ${opt.title} · ${_fmt(g.currentWeightKg)} → ${_fmt(g.targetWeightKg)} kg',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
          ),
        ),
        const SectionTitle('Your daily macros', subtitle: 'Calculated for your body and activity level'),
        Row(children: [
          Expanded(child: MetricTile(label: 'Protein', value: '${g.dailyProteinG}', unit: 'g', icon: Icons.egg_alt_rounded, color: AppColors.blue)),
          const SizedBox(width: 10),
          Expanded(child: MetricTile(label: 'Carbs', value: '${g.dailyCarbsG}', unit: 'g', icon: Icons.rice_bowl_rounded, color: AppColors.amber)),
          const SizedBox(width: 10),
          Expanded(child: MetricTile(label: 'Fat', value: '${g.dailyFatG}', unit: 'g', icon: Icons.water_drop_rounded, color: AppColors.pink)),
        ]),
        const SizedBox(height: 16),
        AppCard(
          color: AppColors.greenSoft,
          shadow: false,
          child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('🥗', style: TextStyle(fontSize: 22)),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Your Fuel Log and Health Report now use these targets. Log meals daily to see how close you get.',
                style: TextStyle(fontSize: 13.5, height: 1.45, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  static String _fmt(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.option, required this.selected, required this.onTap});
  final _GoalOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: selected ? option.color : Colors.transparent, width: 2),
          boxShadow: selected ? AppShadows.glow(option.color) : AppShadows.card,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: 120,
            width: double.infinity,
            child: Stack(fit: StackFit.expand, children: [
              Image.asset(option.image, fit: BoxFit.cover),
              const PhotoScrim(strength: 0.55),
              Positioned(
                left: 14,
                bottom: 12,
                child: Tag(option.hindi, color: Colors.white, bg: Colors.black.withValues(alpha: 0.35)),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(children: [
              IconBubble(option.icon, color: option.color, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(option.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(option.subtitle,
                      style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w500)),
                ]),
              ),
              Radio<String>(value: option.id, activeColor: option.color),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.activity, required this.selected, required this.onTap});
  final _Activity activity;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primarySoft : AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? AppColors.primary : AppColors.line, width: selected ? 1.6 : 1),
        ),
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
            child: Text(activity.emoji, style: const TextStyle(fontSize: 24)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(activity.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(activity.subtitle,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w500)),
            ]),
          ),
          Radio<String>(value: activity.id),
        ]),
      ),
    );
  }
}

class _IntStepper extends StatelessWidget {
  const _IntStepper({required this.value, required this.min, required this.max, required this.onChanged});
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i, int? next) => Tap(
          onTap: next == null ? null : () => onChanged(next),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: next == null ? AppColors.surfaceAlt : AppColors.primarySoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(i, color: next == null ? AppColors.text3 : AppColors.primary, size: 20),
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      btn(Icons.remove_rounded, value > min ? value - 1 : null),
      SizedBox(
        width: 54,
        child: Text('$value',
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      ),
      btn(Icons.add_rounded, value < max ? value + 1 : null),
    ]);
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.unit,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.color = AppColors.primary,
  });
  final String label;
  final double value;
  final String unit;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(min, max).toDouble();
    final step = (max - min) / divisions;
    return Column(children: [
      Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
        _nudge(Icons.remove_rounded, v - step >= min ? () => onChanged(v - step) : null),
        SizedBox(
          width: 86,
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1),
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
              TextSpan(text: ' $unit', style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w700)),
            ]),
            textAlign: TextAlign.center,
          ),
        ),
        _nudge(Icons.add_rounded, v + step <= max ? () => onChanged(v + step) : null),
      ]),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: color,
          thumbColor: color,
          overlayColor: color.withValues(alpha: 0.12),
          trackHeight: 5,
        ),
        child: Slider(value: v, min: min, max: max, divisions: divisions, onChanged: onChanged),
      ),
    ]);
  }

  Widget _nudge(IconData icon, VoidCallback? onTap) => Tap(
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 18, color: onTap == null ? AppColors.text3 : AppColors.text),
        ),
      );
}
