import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../state/session.dart';

/// 1. Goal-Based Onboarding & User Profiling
/// Collects initial fitness targets to automatically derive daily recommended calorie
/// and nutrient baselines for progress analytics in the Gym Health Report.
class GoalSelectionScreen extends StatefulWidget {
  const GoalSelectionScreen({super.key, this.isEditing = false});

  final bool isEditing;

  @override
  State<GoalSelectionScreen> createState() => _GoalSelectionScreenState();
}

class _GoalSelectionScreenState extends State<GoalSelectionScreen> {
  String _selectedGoal = 'weight_loss'; // weight_loss | muscle_gain | maintenance
  String _gender = 'male';
  late final TextEditingController _age;
  late final TextEditingController _height;
  late final TextEditingController _currentWeight;
  late final TextEditingController _targetWeight;
  String _activityLevel = 'moderate'; // sedentary | light | moderate | very_active

  bool _loading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _age = TextEditingController(text: '26');
    _height = TextEditingController(text: '175');
    _currentWeight = TextEditingController(text: '75');
    _targetWeight = TextEditingController(text: '70');

    _loadExistingGoal();
  }

  Future<void> _loadExistingGoal() async {
    setState(() => _loading = true);
    try {
      final goal = await context.read<Session>().api.goal();
      if (goal != null && mounted) {
        setState(() {
          _selectedGoal = goal.goalType;
          _gender = goal.gender;
          _age.text = goal.age.toString();
          _height.text = goal.heightCm.round().toString();
          _currentWeight.text = goal.currentWeightKg.round().toString();
          _targetWeight.text = goal.targetWeightKg.round().toString();
          _activityLevel = goal.activityLevel;
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _age.dispose();
    _height.dispose();
    _currentWeight.dispose();
    _targetWeight.dispose();
    super.dispose();
  }

  // Live calculation preview
  ({int cals, int protein, int carbs, int fat}) _calcPreview() {
    final age = int.tryParse(_age.text) ?? 26;
    final height = double.tryParse(_height.text) ?? 175;
    final weight = double.tryParse(_currentWeight.text) ?? 75;

    double bmr = 10 * weight + 6.25 * height - 5 * age;
    bmr = _gender == 'male' ? bmr + 5 : bmr - 161;

    final mult = switch (_activityLevel) {
      'sedentary' => 1.2,
      'light' => 1.375,
      'very_active' => 1.725,
      _ => 1.55,
    };
    final tdee = (bmr * mult).round();

    int targetCals = switch (_selectedGoal) {
      'weight_loss' => (tdee - 500).clamp(1200, 5000),
      'muscle_gain' => tdee + 400,
      _ => tdee,
    };

    final pMult = switch (_selectedGoal) {
      'muscle_gain' => 2.0,
      'weight_loss' => 1.8,
      _ => 1.5,
    };
    final pG = (weight * pMult).round();
    final fG = ((targetCals * 0.25) / 9).round();
    final cG = (((targetCals - (pG * 4) - (fG * 9)).clamp(0, 10000)) / 4).round();

    return (cals: targetCals, protein: pG, carbs: cG, fat: fG);
  }

  Future<void> _save() async {
    final age = int.tryParse(_age.text);
    final height = double.tryParse(_height.text);
    final currentWeight = double.tryParse(_currentWeight.text);
    final targetWeight = double.tryParse(_targetWeight.text);

    if (age == null || age < 12 || age > 100) {
      showSnack(context, 'Please enter a valid age (12–100)', error: true);
      return;
    }
    if (height == null || height < 80 || height > 250) {
      showSnack(context, 'Please enter a valid height in cm (80–250)', error: true);
      return;
    }
    if (currentWeight == null || currentWeight < 30 || currentWeight > 300) {
      showSnack(context, 'Please enter your current weight in kg', error: true);
      return;
    }
    if (targetWeight == null || targetWeight < 30 || targetWeight > 300) {
      showSnack(context, 'Please enter your target weight in kg', error: true);
      return;
    }

    setState(() => _saving = true);
    try {
      await context.read<Session>().api.saveGoal({
        'goalType': _selectedGoal,
        'age': age,
        'gender': _gender,
        'heightCm': height,
        'currentWeightKg': currentWeight,
        'targetWeightKg': targetWeight,
        'activityLevel': _activityLevel,
      });

      if (mounted) {
        showSnack(context, 'Fitness targets configured successfully!');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final preview = _calcPreview();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Goal & Fitness Targets'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Text('Step 1 & 2: Select Your Primary Goal', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text(
              'Your goal determines your calorie and nutrient baseline calculations for the Gym Health Report.',
              style: TextStyle(color: FkColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _goalCard(
              id: 'weight_loss',
              title: 'Goal A: Weight Loss',
              subtitle: 'Caloric deficit calculation (Patla hona hai)',
              icon: Icons.trending_down,
              color: FkColors.orange,
            ),
            const SizedBox(height: 10),
            _goalCard(
              id: 'muscle_gain',
              title: 'Goal B: Muscle / Weight Gain',
              subtitle: 'Caloric surplus calculation (Bulk / Mota hona hai)',
              icon: Icons.fitness_center,
              color: FkColors.lime,
            ),
            const SizedBox(height: 10),
            _goalCard(
              id: 'maintenance',
              title: 'Goal C: Maintenance',
              subtitle: 'Isocaloric maintenance (Jaisa hoon waisa rehna hai)',
              icon: Icons.balance,
              color: FkColors.sky,
            ),
            const SizedBox(height: 24),
            Text('Step 3: Input Parameters', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),

            // Gender
            const Text('Gender', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'male', label: Text('Male')),
                ButtonSegment(value: 'female', label: Text('Female')),
                ButtonSegment(value: 'other', label: Text('Other')),
              ],
              selected: {_gender},
              onSelectionChanged: (s) => setState(() => _gender = s.first),
            ),
            const SizedBox(height: 16),

            // Age & Height
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Age (years)', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _age,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: 'e.g. 26', suffixText: 'yrs'),
                    onChanged: (_) => setState(() {}),
                  ),
                ]),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Height', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _height,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: 'e.g. 175', suffixText: 'cm'),
                    onChanged: (_) => setState(() {}),
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: 16),

            // Weights
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Current Weight', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _currentWeight,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: 'e.g. 75', suffixText: 'kg'),
                    onChanged: (_) => setState(() {}),
                  ),
                ]),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Target Weight', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _targetWeight,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: 'e.g. 70', suffixText: 'kg'),
                    onChanged: (_) => setState(() {}),
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: 16),

            // Activity level
            const Text('Activity Level', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _activityLevel,
              decoration: const InputDecoration(),
              items: const [
                DropdownMenuItem(value: 'sedentary', child: Text('Sedentary (desk job, little exercise)')),
                DropdownMenuItem(value: 'light', child: Text('Lightly Active (1–3 workout days/wk)')),
                DropdownMenuItem(value: 'moderate', child: Text('Moderately Active (3–5 workout days/wk)')),
                DropdownMenuItem(value: 'very_active', child: Text('Very Active (6–7 heavy workouts/wk)')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _activityLevel = v);
              },
            ),
            const SizedBox(height: 24),

            // Derived Targets Preview Box
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: FkColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: FkColors.lime.withValues(alpha: 0.5), width: 1.5),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.auto_awesome, color: FkColors.lime, size: 20),
                  const SizedBox(width: 8),
                  const Text('Derived Daily Targets (Preview)', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: _targetTile('Calories', '${preview.cals} kcal', FkColors.lime),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _targetTile('Protein', '${preview.protein} g', FkColors.sky),
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: _targetTile('Carbs', '${preview.carbs} g', FkColors.orange),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _targetTile('Healthy Fats', '${preview.fat} g', FkColors.violet),
                  ),
                ]),
              ]),
            ),
            const SizedBox(height: 28),

            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('Save & Apply Targets'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _targetTile(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: const Color(0xFF1E232B), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: FkColors.textSecondary)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
      ]),
    );
  }

  Widget _goalCard({
    required String id,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    final selected = _selectedGoal == id;
    return InkWell(
      onTap: () => setState(() => _selectedGoal = id),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.15) : FkColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? color : FkColors.outline,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: FkColors.textSecondary, fontSize: 12)),
            ]),
          ),
          Radio<String>(
            value: id,
            groupValue: _selectedGoal,
            activeColor: color,
            onChanged: (v) {
              if (v != null) setState(() => _selectedGoal = v);
            },
          ),
        ]),
      ),
    );
  }
}
