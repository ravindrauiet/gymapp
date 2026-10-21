import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';

/// AI Plate & Nutrition Label Scanner.
/// Takes or uploads a photo of food or nutrition facts label,
/// invokes ChatGPT Vision (GPT-4o-mini), and auto-populates the Fuel Log.
class AiFoodScannerScreen extends StatefulWidget {
  const AiFoodScannerScreen({super.key, this.defaultMealType = 'breakfast'});

  final String defaultMealType;

  @override
  State<AiFoodScannerScreen> createState() => _AiFoodScannerScreenState();
}

class _AiFoodScannerScreenState extends State<AiFoodScannerScreen> {
  final ImagePicker _picker = ImagePicker();

  Uint8List? _imageBytes;
  bool _isAnalyzing = false;
  FoodItem? _extractedFood;
  String? _error;

  late String _selectedMeal;
  double _servings = 1.0;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _servingUnitController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedMeal = widget.defaultMealType;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _servingUnitController.dispose();
    super.dispose();
  }

  Future<void> _pickAndAnalyze(ImageSource source) async {
    final api = context.read<Session>().api;
    try {
      final XFile? file = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (file == null) return;

      final bytes = await file.readAsBytes();
      final base64String = base64Encode(bytes);

      if (!mounted) return;
      setState(() {
        _imageBytes = bytes;
        _isAnalyzing = true;
        _error = null;
        _extractedFood = null;
      });

      final food = await api.extractNutritionFromImage(base64String);

      if (!mounted) return;
      setState(() {
        _extractedFood = food;
        _nameController.text = food.name;
        _servingUnitController.text = food.servingUnit;
        _servings = 1.0;
        _isAnalyzing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isAnalyzing = false;
        _error = errorMessage(e);
      });
      showSnack(context, _error!, error: true);
    }
  }

  Future<void> _logExtractedMeal() async {
    final food = _extractedFood;
    if (food == null) return;

    final cals = (food.calories * _servings).round();
    final prot = ((food.proteinG * _servings) * 10).round() / 10;
    final carb = ((food.carbsG * _servings) * 10).round() / 10;
    final fat = ((food.fatG * _servings) * 10).round() / 10;
    final foodName = _nameController.text.trim().isNotEmpty ? _nameController.text.trim() : food.name;

    try {
      await context.read<Session>().api.logMeal({
        'mealType': _selectedMeal,
        'foodName': foodName,
        'servings': _servings,
        'calories': cals,
        'proteinG': prot,
        'carbsG': carb,
        'fatG': fat,
      });

      if (!mounted) return;
      showSnack(context, 'Logged $_servings x "$foodName" to ${_selectedMeal.toUpperCase()}!');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Meal & Label Scanner'),
        actions: [
          IconButton(
            tooltip: 'How it works',
            icon: const Icon(Icons.info_outline),
            onPressed: _showInfoDialog,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top guidance badge
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: FkColors.lime.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: FkColors.lime.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.auto_awesome, color: FkColors.lime, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Powered by ChatGPT Vision (GPT-4o). Snap any meal plate or nutrition label to extract calories & macros.',
                      style: TextStyle(fontSize: 12, color: Colors.white, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // Image display / Camera actions
            if (_imageBytes == null) ...[
              _buildCaptureCard(),
            ] else ...[
              _buildImagePreview(),
            ],

            const SizedBox(height: 20),

            // Analysis state or extracted fields
            if (_isAnalyzing) ...[
              _buildAnalyzingState(),
            ] else if (_extractedFood != null) ...[
              _buildExtractedFoodEditor(),
            ] else if (_error != null) ...[
              _buildErrorRetryCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCaptureCard() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      decoration: BoxDecoration(
        color: FkColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: FkColors.outline),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: FkColors.lime.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.camera_alt, color: FkColors.lime, size: 44),
          ),
          const SizedBox(height: 18),
          const Text(
            'Snap Food or Nutrition Label',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          const Text(
            'Take a photo of your cooked meal, thali, salad, or product facts label.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: FkColors.textSecondary),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.camera),
                  label: const Text('Camera'),
                  onPressed: () => _pickAndAnalyze(ImageSource.camera),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Gallery'),
                  onPressed: () => _pickAndAnalyze(ImageSource.gallery),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildImagePreview() {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.memory(
            _imageBytes!,
            height: 220,
            width: double.infinity,
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: IconButton.filledTonal(
            tooltip: 'Retake photo',
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () => setState(() {
              _imageBytes = null;
              _extractedFood = null;
              _error = null;
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildAnalyzingState() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: FkColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FkColors.lime.withValues(alpha: 0.4)),
      ),
      child: const Column(
        children: [
          CircularProgressIndicator(color: FkColors.lime),
          SizedBox(height: 16),
          Text(
            'Analyzing with ChatGPT Vision...',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          SizedBox(height: 6),
          Text(
            'Identifying dish composition, portion size, calories, protein, carbs & minerals.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: FkColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorRetryCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: FkColors.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FkColors.danger.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          const Icon(Icons.error_outline, color: FkColors.danger, size: 36),
          const SizedBox(height: 8),
          const Text('Analysis Failed', style: TextStyle(fontWeight: FontWeight.w800, color: FkColors.danger)),
          const SizedBox(height: 4),
          Text(_error ?? 'Could not parse food image.',
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          const SizedBox(height: 14),
          FilledButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Try Another Photo'),
            onPressed: () => setState(() {
              _imageBytes = null;
              _error = null;
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildExtractedFoodEditor() {
    final food = _extractedFood!;
    final cals = (food.calories * _servings).round();
    final prot = ((food.proteinG * _servings) * 10).round() / 10;
    final carb = ((food.carbsG * _servings) * 10).round() / 10;
    final fat = ((food.fatG * _servings) * 10).round() / 10;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Extracted Food Header
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: FkColors.lime.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        food.category.toUpperCase(),
                        style: const TextStyle(color: FkColors.lime, fontSize: 11, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const Spacer(),
                    const Icon(Icons.check_circle, color: FkColors.lime, size: 18),
                    const SizedBox(width: 4),
                    const Text('AI Verified', style: TextStyle(color: FkColors.lime, fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Food / Dish Title',
                    isDense: true,
                    prefixIcon: Icon(Icons.restaurant),
                  ),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _servingUnitController,
                  decoration: const InputDecoration(
                    labelText: 'Serving Reference (per 1x)',
                    isDense: true,
                    prefixIcon: Icon(Icons.straighten),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 14),

        // Live Macro Grid
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: FkColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: FkColors.outline),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _macroBox('Calories', '$cals kcal', FkColors.lime),
                  _macroBox('Protein', '${prot}g', FkColors.sky),
                  _macroBox('Carbs', '${carb}g', FkColors.orange),
                  _macroBox('Fats', '${fat}g', FkColors.violet),
                ],
              ),
              const Divider(height: 24),
              // Micronutrients row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _microLabel('Fibre', '${(food.fibreG * _servings).toStringAsFixed(1)}g'),
                  _microLabel('Iron', '${(food.ironMg * _servings).toStringAsFixed(1)}mg'),
                  _microLabel('Calcium', '${(food.calciumMg * _servings).round()}mg'),
                  _microLabel('Magnesium', '${(food.magnesiumMg * _servings).round()}mg'),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // Portion & Category Selector
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Portion Size', style: TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      '${_servings.toStringAsFixed(1)}x serving',
                      style: const TextStyle(fontWeight: FontWeight.w900, color: FkColors.lime, fontSize: 15),
                    ),
                  ],
                ),
                Slider(
                  value: _servings,
                  min: 0.5,
                  max: 5.0,
                  divisions: 9,
                  activeColor: FkColors.lime,
                  onChanged: (v) => setState(() => _servings = v),
                ),
                const SizedBox(height: 12),
                const Text('Log to Meal Category', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _selectedMeal,
                  items: const [
                    DropdownMenuItem(value: 'breakfast', child: Text('Breakfast 🍳')),
                    DropdownMenuItem(value: 'lunch', child: Text('Lunch 🥗')),
                    DropdownMenuItem(value: 'snacks', child: Text('Evening Snacks ☕')),
                    DropdownMenuItem(value: 'dinner', child: Text('Dinner 🍲')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _selectedMeal = v);
                  },
                ),
              ],
            ),
          ),
        ),

        // Educational AI note
        if (food.educationalNotes != null && food.educationalNotes!.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: FkColors.sky.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: FkColors.sky.withValues(alpha: 0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb_outline, color: FkColors.sky, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Coach Insight',
                          style: TextStyle(color: FkColors.sky, fontWeight: FontWeight.w800, fontSize: 12)),
                      const SizedBox(height: 2),
                      Text(food.educationalNotes!,
                          style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.3)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 24),

        // Final 1-Tap CTA
        FilledButton.icon(
          icon: const Icon(Icons.add_task),
          label: Text('Log $_selectedMeal ($cals kcal) to Fuel Log'),
          onPressed: _logExtractedMeal,
        ),
      ],
    );
  }

  Widget _macroBox(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: color)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: FkColors.textSecondary)),
      ],
    );
  }

  Widget _microLabel(String name, String value) {
    return Column(
      children: [
        Text(name, style: const TextStyle(fontSize: 11, color: FkColors.textSecondary)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ],
    );
  }

  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI Nutrition Vision'),
        content: const Text(
          'FitKey uses OpenAI GPT-4o-mini Vision to analyze meal photos and packaged food labels.\n\n'
          'Tips for best results:\n'
          '• For cooked food: Frame the full plate or bowl with decent lighting.\n'
          '• For packaged goods: Snap the "Nutrition Facts" panel or ingredients list.\n'
          '• You can adjust the portion multiplier and edit the dish name before saving.',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
      ),
    );
  }
}
