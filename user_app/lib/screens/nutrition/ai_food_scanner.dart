import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';

/// Meal type that fits the current time of day.
String mealTypeForNow([DateTime? at]) {
  final h = (at ?? DateTime.now()).hour;
  if (h < 11) return 'breakfast';
  if (h < 16) return 'lunch';
  if (h < 19) return 'snacks';
  return 'dinner';
}

const _mealTypes = [
  ('breakfast', 'Breakfast', '🍳'),
  ('lunch', 'Lunch', '🍛'),
  ('snacks', 'Snacks', '☕'),
  ('dinner', 'Dinner', '🍲'),
];

/// AI meal & nutrition-label scanner: photo → GPT vision on the API → editable result → Fuel Log.
/// Pops with `true` when a meal was logged.
class AiFoodScannerScreen extends StatefulWidget {
  const AiFoodScannerScreen({super.key, this.defaultMealType});

  final String? defaultMealType;

  @override
  State<AiFoodScannerScreen> createState() => _AiFoodScannerScreenState();
}

class _AiFoodScannerScreenState extends State<AiFoodScannerScreen> {
  final _picker = ImagePicker();
  final _name = TextEditingController();
  final _unit = TextEditingController();

  String _mode = 'meal'; // meal | label
  Uint8List? _image;
  bool _analyzing = false;
  bool _saving = false;
  FoodItem? _food;
  Object? _error;
  late String _meal = widget.defaultMealType ?? mealTypeForNow();
  double _servings = 1;

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    final api = context.read<Session>().api;
    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: source,
        // Labels need small print to stay legible.
        maxWidth: _mode == 'label' ? 1600 : 1024,
        maxHeight: _mode == 'label' ? 1600 : 1024,
        imageQuality: 85,
      );
    } catch (_) {
      if (mounted) toast(context, 'Could not open the ${source == ImageSource.camera ? 'camera' : 'gallery'}', error: true);
      return;
    }
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _image = bytes;
      _analyzing = true;
      _error = null;
      _food = null;
    });
    try {
      final food = await api.extractNutritionFromImage(base64Encode(bytes), mode: _mode);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _food = food;
        _name.text = food.name;
        _unit.text = food.servingUnit;
        _servings = 1;
        _analyzing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _analyzing = false;
        _error = e;
      });
    }
  }

  void _reset() => setState(() {
        _image = null;
        _food = null;
        _error = null;
      });

  double _r1(double v) => (v * _servings * 10).round() / 10;

  Future<void> _log() async {
    final food = _food!;
    setState(() => _saving = true);
    final name = _name.text.trim().isEmpty ? food.name : _name.text.trim();
    try {
      await context.read<Session>().api.logMeal({
        'mealType': _meal,
        'foodName': name,
        'servings': _servings,
        'calories': (food.calories * _servings).round(),
        'proteinG': _r1(food.proteinG),
        'carbsG': _r1(food.carbsG),
        'fatG': _r1(food.fatG),
      });
      if (!mounted) return;
      final label = _mealTypes.firstWhere((m) => m.$1 == _meal).$2;
      toast(context, 'Added to $label');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final food = _food;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Meal Scanner'),
        actions: [
          if (_image != null && !_analyzing)
            TextButton.icon(onPressed: _reset, icon: const Icon(Icons.refresh_rounded, size: 18), label: const Text('Retake')),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
        if (_image == null) ...[
          _ModeSwitch(mode: _mode, onChanged: (m) => setState(() => _mode = m)),
          const SizedBox(height: 16),
          _CaptureCard(mode: _mode, onPick: _pick),
          const SizedBox(height: 20),
          _Tips(mode: _mode),
        ] else ...[
          _Preview(image: _image!, scanning: _analyzing),
          const SizedBox(height: 16),
          if (_analyzing)
            _AnalyzingCard(mode: _mode)
          else if (_error != null)
            AppCard(
              child: Column(children: [
                const IconBubble(Icons.image_not_supported_rounded, color: AppColors.red, size: 52),
                const SizedBox(height: 12),
                const Text('Couldn\'t read that photo', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(friendlyError(_error!), textAlign: TextAlign.center, style: const TextStyle(color: AppColors.text2)),
                const SizedBox(height: 16),
                AppButton(label: 'Try another photo', icon: Icons.photo_camera_rounded, onPressed: _reset),
              ]),
            )
          else if (food != null)
            ..._result(food),
        ],
      ]),
      bottomNavigationBar: food == null || _analyzing
          ? null
          : BottomActionBar(
              child: AppButton(
                label:
                    'Add to ${_mealTypes.firstWhere((m) => m.$1 == _meal).$2} · ${(food.calories * _servings).round()} kcal',
                icon: Icons.add_circle_rounded,
                busy: _saving,
                color: AppColors.green,
                onPressed: _log,
              ),
            ),
    );
  }

  List<Widget> _result(FoodItem food) {
    final kcal = (food.calories * _servings).round();
    return [
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Tag(food.category.toUpperCase(), color: AppColors.green, dense: true),
            const Spacer(),
            const Icon(Icons.auto_awesome_rounded, size: 15, color: AppColors.purple),
            const SizedBox(width: 4),
            Text(_mode == 'label' ? 'Read from label' : 'AI estimate',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.purple)),
          ]),
          const SizedBox(height: 14),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            decoration: const InputDecoration(labelText: 'Food name', prefixIcon: Icon(Icons.restaurant_rounded)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _unit,
            decoration: const InputDecoration(labelText: 'One serving is', prefixIcon: Icon(Icons.straighten_rounded)),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      AppCard(
        child: Column(children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$kcal',
                    style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: -1.2, height: 1)),
                const Text('kcal', style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700)),
              ]),
            ),
            _ServingStepper(value: _servings, onChanged: (v) => setState(() => _servings = v)),
          ]),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: _Macro('Protein', _r1(food.proteinG), AppColors.blue)),
            const SizedBox(width: 10),
            Expanded(child: _Macro('Carbs', _r1(food.carbsG), AppColors.amber)),
            const SizedBox(width: 10),
            Expanded(child: _Macro('Fat', _r1(food.fatG), AppColors.pink)),
          ]),
          const SizedBox(height: 14),
          const Divider(),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _Micro('Fibre', '${_r1(food.fibreG)} g'),
            _Micro('Iron', '${_r1(food.ironMg)} mg'),
            _Micro('Calcium', '${(food.calciumMg * _servings).round()} mg'),
            _Micro('Sodium', '${(food.sodiumMg * _servings).round()} mg'),
          ]),
        ]),
      ),
      const SizedBox(height: 14),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Add to', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 10),
          Row(children: [
            for (final (id, label, emoji) in _mealTypes)
              Expanded(
                child: Tap(
                  onTap: () => setState(() => _meal = id),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: _meal == id ? AppColors.greenSoft : AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _meal == id ? AppColors.green : AppColors.line, width: 1.4),
                    ),
                    child: Column(children: [
                      Text(emoji, style: const TextStyle(fontSize: 20)),
                      const SizedBox(height: 2),
                      Text(label,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: _meal == id ? AppColors.green : AppColors.text2)),
                    ]),
                  ),
                ),
              ),
          ]),
        ]),
      ),
      if ((food.educationalNotes ?? '').isNotEmpty) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.purpleSoft, borderRadius: BorderRadius.circular(18)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const MansiAvatar(size: 30, animate: false),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Mansi\'s tip', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.purple)),
                const SizedBox(height: 2),
                Text(food.educationalNotes!, style: const TextStyle(fontSize: 13, height: 1.45, color: AppColors.text)),
              ]),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 10),
      const Text('Values are AI estimates — adjust the name or servings before adding.',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: AppColors.text3)),
    ];
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});
  final String mode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget seg(String id, IconData icon, String label) {
      final on = mode == id;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 44,
            decoration: BoxDecoration(
              color: on ? AppColors.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              boxShadow: on ? AppShadows.soft : null,
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 18, color: on ? AppColors.primary : AppColors.text2),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontWeight: FontWeight.w800, color: on ? AppColors.text : AppColors.text2)),
            ]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(15)),
      child: Row(children: [
        seg('meal', Icons.restaurant_rounded, 'Meal photo'),
        seg('label', Icons.receipt_long_rounded, 'Nutrition label'),
      ]),
    );
  }
}

class _CaptureCard extends StatelessWidget {
  const _CaptureCard({required this.mode, required this.onPick});
  final String mode;
  final ValueChanged<ImageSource> onPick;

  @override
  Widget build(BuildContext context) {
    final label = mode == 'label';
    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: AppShadows.card, color: AppColors.surface),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        SizedBox(
          height: 210,
          child: Stack(fit: StackFit.expand, children: [
            Image.asset(label ? AppImages.supplements : AppImages.foodPlate, fit: BoxFit.cover),
            const PhotoScrim(strength: 0.8),
            Positioned(
              left: 18,
              right: 18,
              bottom: 16,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Tag('POWERED BY AI', color: AppColors.ink, bg: AppColors.lime, icon: Icons.auto_awesome_rounded, dense: true),
                const SizedBox(height: 8),
                Text(label ? 'Snap the nutrition label' : 'Snap your plate',
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                Text(
                    label
                        ? 'We read calories, protein, carbs & more straight off the pack'
                        : 'Calories, protein, carbs & fat estimated in seconds',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
              ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(
              child: AppButton(label: 'Camera', icon: Icons.photo_camera_rounded, onPressed: () => onPick(ImageSource.camera)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 54,
                child: OutlinedButton.icon(
                  onPressed: () => onPick(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_rounded),
                  label: const Text('Gallery'),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Tips extends StatelessWidget {
  const _Tips({required this.mode});
  final String mode;

  @override
  Widget build(BuildContext context) {
    final tips = mode == 'label'
        ? const [
            (Icons.crop_free_rounded, 'Fill the frame with the "Nutrition Information" panel'),
            (Icons.wb_sunny_outlined, 'Avoid glare — tilt the pack away from lights'),
            (Icons.zoom_in_rounded, 'Keep the small print sharp and in focus'),
          ]
        : const [
            (Icons.crop_free_rounded, 'Fit the whole plate or bowl in the photo'),
            (Icons.wb_sunny_outlined, 'Good light gives better estimates'),
            (Icons.edit_note_rounded, 'You can fix the name and portion before saving'),
          ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('For best results', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      const SizedBox(height: 10),
      for (final (icon, text) in tips)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            IconBubble(icon, color: AppColors.green, size: 34),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600))),
          ]),
        ),
    ]);
  }
}

class _Preview extends StatefulWidget {
  const _Preview({required this.image, required this.scanning});
  final Uint8List image;
  final bool scanning;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        height: 240,
        child: Stack(fit: StackFit.expand, children: [
          Image.memory(widget.image, fit: BoxFit.cover),
          if (widget.scanning) ...[
            Container(color: Colors.black.withValues(alpha: 0.25)),
            AnimatedBuilder(
              animation: _c,
              builder: (_, _) => Align(
                alignment: Alignment(0, -1 + 2 * _c.value),
                child: Container(
                  height: 3,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.lime,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [BoxShadow(color: AppColors.lime.withValues(alpha: 0.8), blurRadius: 16, spreadRadius: 2)],
                  ),
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _AnalyzingCard extends StatelessWidget {
  const _AnalyzingCard({required this.mode});
  final String mode;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(children: [
        const MansiAvatar(size: 46),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mode == 'label' ? 'Reading the label…' : 'Analysing your plate…',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 3),
            Text(
                mode == 'label'
                    ? 'Extracting calories, macros & minerals'
                    : 'Identifying dishes and estimating portions',
                style: const TextStyle(color: AppColors.text2, fontSize: 13)),
            const SizedBox(height: 10),
            const ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(4)),
              child: LinearProgressIndicator(minHeight: 4, color: AppColors.purple),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _ServingStepper extends StatelessWidget {
  const _ServingStepper({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i, double next) => Tap(
          onTap: next < 0.5 || next > 10 ? null : () => onChanged(next),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10), boxShadow: AppShadows.soft),
            child: Icon(i, size: 18, color: AppColors.green),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        btn(Icons.remove_rounded, value - 0.5),
        SizedBox(
          width: 70,
          child: Column(children: [
            Text('${value % 1 == 0 ? value.toInt() : value}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.green)),
            Text(value == 1 ? 'serving' : 'servings',
                style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.green)),
          ]),
        ),
        btn(Icons.add_rounded, value + 0.5),
      ]),
    );
  }
}

class _Macro extends StatelessWidget {
  const _Macro(this.label, this.grams, this.color);
  final String label;
  final double grams;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${grams % 1 == 0 ? grams.toInt() : grams} g',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: color)),
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.text2)),
      ]),
    );
  }
}

class _Micro extends StatelessWidget {
  const _Micro(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
    ]);
  }
}
