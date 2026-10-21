import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import '../ai/ai_coach_screen.dart';
import 'ai_food_scanner.dart';
import 'barcode_scanner_screen.dart';

/// 3. "Fuel Log" (Nutrition & Meal Tracker Module)
class FuelLogScreen extends StatefulWidget {
  const FuelLogScreen({super.key});

  @override
  State<FuelLogScreen> createState() => _FuelLogScreenState();
}

class _FuelLogScreenState extends State<FuelLogScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late Future<MealDailySummary> _mealFuture;
  late Future<List<FoodItem>> _encyclopediaFuture;
  final TextEditingController _encyclopediaSearch = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadMeals();
    _loadEncyclopedia();
  }

  void _loadMeals() {
    _mealFuture = context.read<Session>().api.dailyMeals();
  }

  void _loadEncyclopedia() {
    _encyclopediaFuture = context.read<Session>().api.foodEncyclopedia(
          q: _encyclopediaSearch.text.trim().isEmpty ? null : _encyclopediaSearch.text.trim(),
        );
  }

  void _reloadMeals() => setState(_loadMeals);
  void _reloadEncyclopedia() => setState(_loadEncyclopedia);

  @override
  void dispose() {
    _tabController.dispose();
    _encyclopediaSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fuel Log (Nutrition)'),
        actions: [
          IconButton(
            tooltip: 'FitKey AI Coach',
            icon: const Icon(Icons.smart_toy, color: FkColors.sky),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiCoachScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Snap Food or Label with AI',
            icon: const Icon(Icons.camera_alt, color: FkColors.lime),
            onPressed: () async {
              final logged = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const AiFoodScannerScreen()),
              );
              if (logged == true) _reloadMeals();
            },
          ),
          IconButton(
            tooltip: 'Scan Barcode',
            icon: const Icon(Icons.qr_code_scanner, color: Colors.white70),
            onPressed: () async {
              final logged = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const BarcodeScannerScreen()),
              );
              if (logged == true) _reloadMeals();
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.restaurant), text: 'Daily Tracker'),
            Tab(icon: Icon(Icons.menu_book), text: 'Food Encyclopedia'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDailyTrackerTab(),
          _buildEncyclopediaTab(),
        ],
      ),
    );
  }

  // ============================================================================
  // Module B: Daily Meal Tracker (Intake Logger)
  // ============================================================================
  Widget _buildDailyTrackerTab() {
    return FutureBuilder<MealDailySummary>(
      future: _mealFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return ErrorState(message: errorMessage(snap.error!), onRetry: _reloadMeals);
        }

        final data = snap.data!;
        final calPercent = data.calorieTarget > 0 ? (data.totalCalories / data.calorieTarget).clamp(0.0, 1.0) : 0.0;
        final proPercent = data.proteinTarget > 0 ? (data.totalProteinG / data.proteinTarget).clamp(0.0, 1.0) : 0.0;
        final carbPercent = data.carbsTarget > 0 ? (data.totalCarbsG / data.carbsTarget).clamp(0.0, 1.0) : 0.0;
        final fatPercent = data.fatTarget > 0 ? (data.totalFatG / data.fatTarget).clamp(0.0, 1.0) : 0.0;

        return RefreshIndicator(
          onRefresh: () async => _reloadMeals(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              // Smart Push Nudges Card
              if (data.nudges.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: FkColors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: FkColors.orange.withValues(alpha: 0.4)),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.notifications_active, color: FkColors.orange, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Nutrition Nudge',
                              style: TextStyle(color: FkColors.orange, fontWeight: FontWeight.w800, fontSize: 13)),
                          const SizedBox(height: 2),
                          Text(data.nudges.first,
                              style: const TextStyle(fontSize: 13, height: 1.3, color: Colors.white70)),
                        ],
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
              ],

              // AI Snap & Log Meal Banner
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () async {
                  final logged = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(builder: (_) => const AiFoodScannerScreen()),
                  );
                  if (logged == true) _reloadMeals();
                },
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        FkColors.lime.withValues(alpha: 0.15),
                        FkColors.sky.withValues(alpha: 0.10),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: FkColors.lime.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: FkColors.lime.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.camera_alt, color: FkColors.lime, size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text('AI Food & Label Scanner',
                                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: Colors.white)),
                                SizedBox(width: 6),
                                Icon(Icons.auto_awesome, color: FkColors.lime, size: 14),
                              ],
                            ),
                            SizedBox(height: 2),
                            Text('Take a photo of food or label to extract & log macros with ChatGPT',
                                style: TextStyle(fontSize: 11, color: FkColors.textSecondary, height: 1.25)),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: FkColors.lime),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Live Progress Indicators Box
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: FkColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: FkColors.outline),
                ),
                child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Total Calories', style: TextStyle(color: FkColors.textSecondary, fontSize: 12)),
                      const SizedBox(height: 2),
                      Text('${data.totalCalories} / ${data.calorieTarget} kcal',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: FkColors.lime)),
                    ]),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: FkColors.lime.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        data.calorieBalance,
                        style: const TextStyle(color: FkColors.lime, fontSize: 11, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: calPercent,
                      minHeight: 8,
                      backgroundColor: const Color(0xFF252B35),
                      valueColor: const AlwaysStoppedAnimation(FkColors.lime),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: _macroBar('Protein', '${data.totalProteinG.round()}g', '${data.proteinTarget}g', proPercent, FkColors.sky)),
                    const SizedBox(width: 8),
                    Expanded(child: _macroBar('Carbs', '${data.totalCarbsG.round()}g', '${data.carbsTarget}g', carbPercent, FkColors.orange)),
                    const SizedBox(width: 8),
                    Expanded(child: _macroBar('Fats', '${data.totalFatG.round()}g', '${data.fatTarget}g', fatPercent, FkColors.violet)),
                  ]),
                ]),
              ),
              const SizedBox(height: 24),

              // Meal Categories
              _mealCategorySection('breakfast', 'Breakfast', Icons.wb_sunny_outlined, FkColors.orange, data.breakfast),
              _mealCategorySection('lunch', 'Lunch', Icons.lunch_dining_outlined, FkColors.lime, data.lunch),
              _mealCategorySection('snacks', 'Evening Snacks', Icons.coffee_outlined, FkColors.sky, data.snacks),
              _mealCategorySection('dinner', 'Dinner', Icons.nights_stay_outlined, FkColors.violet, data.dinner),
            ],
          ),
        );
      },
    );
  }

  Widget _macroBar(String label, String current, String target, double percent, Color color) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: FkColors.textSecondary)),
        Text(current, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
      ]),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: percent,
          minHeight: 5,
          backgroundColor: const Color(0xFF252B35),
          valueColor: AlwaysStoppedAnimation(color),
        ),
      ),
      const SizedBox(height: 2),
      Text('Goal: $target', style: const TextStyle(fontSize: 9, color: FkColors.textSecondary)),
    ]);
  }

  Widget _mealCategorySection(
    String type,
    String title,
    IconData icon,
    Color color,
    List<MealLog> items,
  ) {
    final catCalories = items.fold<int>(0, (sum, i) => sum + i.calories);

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const Spacer(),
            Text('$catCalories kcal',
                style: const TextStyle(fontWeight: FontWeight.bold, color: FkColors.textSecondary, fontSize: 13)),
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.add_circle, color: FkColors.lime, size: 22),
              tooltip: 'Log Food to $title',
              onPressed: () => _openQuickLogSheet(type),
            ),
          ]),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('No food logged yet for $title.',
                  style: const TextStyle(color: FkColors.textSecondary, fontSize: 12, fontStyle: FontStyle.italic)),
            )
          else ...[
            const Divider(height: 16),
            ...items.map((it) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(it.foodName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        Text('${it.servings} serving · ${it.proteinG}g P · ${it.carbsG}g C · ${it.fatG}g F',
                            style: const TextStyle(color: FkColors.textSecondary, fontSize: 11)),
                      ]),
                    ),
                    Text('${it.calories} kcal', style: const TextStyle(fontWeight: FontWeight.w700)),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white24),
                      onPressed: () async {
                        await context.read<Session>().api.deleteMeal(it.id);
                        _reloadMeals();
                      },
                    ),
                  ]),
                )),
          ],
        ]),
      ),
    );
  }

  // ============================================================================
  // Module A: Food Encyclopedia (Nutrient Info Bank)
  // ============================================================================
  Widget _buildEncyclopediaTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _encyclopediaSearch,
                  decoration: InputDecoration(
                    hintText: 'Search foods (Egg, Paneer, Oats)...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _encyclopediaSearch.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _encyclopediaSearch.clear();
                              _reloadEncyclopedia();
                            },
                          )
                        : null,
                    isDense: true,
                  ),
                  onSubmitted: (_) => _reloadEncyclopedia(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Scan Barcode',
                icon: const Icon(Icons.qr_code_scanner, color: FkColors.lime),
                onPressed: () async {
                  final logged = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(builder: (_) => const BarcodeScannerScreen()),
                  );
                  if (logged == true) {
                    _reloadMeals();
                    _reloadEncyclopedia();
                  }
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<FoodItem>>(
            future: _encyclopediaFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return ErrorState(message: errorMessage(snap.error!), onRetry: _reloadEncyclopedia);
              }

              final foods = snap.data!;
              if (foods.isEmpty) {
                return const EmptyState(
                  icon: Icons.search_off,
                  title: 'No foods match your search',
                  message: 'Try searching for common foods like Egg, Paneer, Chicken, Oats, Dal.',
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: foods.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, idx) {
                  final f = foods[idx];
                  return Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _showFoodNutrientDialog(f),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(
                              child: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: FkColors.lime.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('${f.calories} kcal',
                                  style: const TextStyle(
                                      color: FkColors.lime, fontWeight: FontWeight.w800, fontSize: 12)),
                            ),
                          ]),
                          const SizedBox(height: 4),
                          Text('Serving: ${f.servingUnit} · ${f.category}',
                              style: const TextStyle(color: FkColors.textSecondary, fontSize: 12)),
                          const SizedBox(height: 8),
                          Row(children: [
                            _macroChip('P: ${f.proteinG}g', FkColors.sky),
                            const SizedBox(width: 6),
                            _macroChip('C: ${f.carbsG}g', FkColors.orange),
                            const SizedBox(width: 6),
                            _macroChip('F: ${f.fatG}g', FkColors.violet),
                            const Spacer(),
                            const Text('View details →',
                                style: TextStyle(color: FkColors.lime, fontSize: 11, fontWeight: FontWeight.bold)),
                          ]),
                        ]),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _macroChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
    );
  }

  void _showFoodNutrientDialog(FoodItem f) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w800)),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Serving size: ${f.servingUnit}', style: const TextStyle(color: FkColors.textSecondary)),
            const Divider(height: 20),
            const Text('Macronutrients', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            _nutrientRow('Energy', '${f.calories} kcal'),
            _nutrientRow('Protein', '${f.proteinG} g'),
            _nutrientRow('Carbohydrates', '${f.carbsG} g'),
            _nutrientRow('Fats', '${f.fatG} g'),
            const SizedBox(height: 12),
            const Text('Micronutrients & Minerals', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            _nutrientRow('Dietary Fibre', '${f.fibreG} g'),
            _nutrientRow('Iron', '${f.ironMg} mg'),
            _nutrientRow('Magnesium', '${f.magnesiumMg} mg'),
            _nutrientRow('Calcium', '${f.calciumMg} mg'),
            _nutrientRow('Sodium', '${f.sodiumMg} mg'),
            if (f.educationalNotes != null) ...[
              const Divider(height: 20),
              const Text('Educational Focus / Health Impact',
                  style: TextStyle(fontWeight: FontWeight.w800, color: FkColors.lime)),
              const SizedBox(height: 4),
              Text(f.educationalNotes!,
                  style: const TextStyle(fontSize: 12, color: FkColors.textSecondary, height: 1.4)),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Log This Food'),
            onPressed: () {
              Navigator.pop(ctx);
              _openLogFoodModal(f);
            },
          ),
        ],
      ),
    );
  }

  Widget _nutrientRow(String name, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(name, style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ]),
    );
  }

  void _openQuickLogSheet(String mealType) async {
    final foods = await context.read<Session>().api.foodEncyclopedia();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Select Food for ${mealType.toUpperCase()}'),
            automaticallyImplyLeading: false,
            actions: [IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx))],
          ),
          body: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: foods.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final f = foods[i];
              return ListTile(
                title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${f.servingUnit} · ${f.calories} kcal'),
                trailing: const Icon(Icons.add_circle_outline, color: FkColors.lime),
                onTap: () {
                  Navigator.pop(ctx);
                  _openLogFoodModal(f, defaultMealType: mealType);
                },
              );
            },
          ),
        ),
      ),
    );
  }

  void _openLogFoodModal(FoodItem food, {String defaultMealType = 'breakfast'}) {
    double servings = 1.0;
    String selectedMeal = defaultMealType;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final cals = (food.calories * servings).round();
          final prot = (food.proteinG * servings * 10).round() / 10;
          final carb = (food.carbsG * servings * 10).round() / 10;
          final fat = (food.fatG * servings * 10).round() / 10;

          return Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Log "${food.name}"', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('Unit: ${food.servingUnit}', style: const TextStyle(color: FkColors.textSecondary)),
                const SizedBox(height: 16),
                const Text('Meal Category', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: selectedMeal,
                  items: const [
                    DropdownMenuItem(value: 'breakfast', child: Text('Breakfast')),
                    DropdownMenuItem(value: 'lunch', child: Text('Lunch')),
                    DropdownMenuItem(value: 'snacks', child: Text('Evening Snacks')),
                    DropdownMenuItem(value: 'dinner', child: Text('Dinner')),
                  ],
                  onChanged: (v) {
                    if (v != null) setSheetState(() => selectedMeal = v);
                  },
                ),
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Serving Quantity', style: TextStyle(fontWeight: FontWeight.w700)),
                  Text('${servings.toStringAsFixed(1)}x',
                      style: const TextStyle(fontWeight: FontWeight.w900, color: FkColors.lime, fontSize: 16)),
                ]),
                Slider(
                  value: servings,
                  min: 0.5,
                  max: 5.0,
                  divisions: 9,
                  activeColor: FkColors.lime,
                  onChanged: (v) => setSheetState(() => servings = v),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFF1E232B), borderRadius: BorderRadius.circular(10)),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                    Text('$cals kcal', style: const TextStyle(fontWeight: FontWeight.bold, color: FkColors.lime)),
                    Text('P: ${prot}g', style: const TextStyle(fontWeight: FontWeight.bold, color: FkColors.sky)),
                    Text('C: ${carb}g', style: const TextStyle(fontWeight: FontWeight.bold, color: FkColors.orange)),
                    Text('F: ${fat}g', style: const TextStyle(fontWeight: FontWeight.bold, color: FkColors.violet)),
                  ]),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await context.read<Session>().api.logMeal({
                      'mealType': selectedMeal,
                      'foodId': food.id,
                      'foodName': food.name,
                      'servings': servings,
                      'calories': cals,
                      'proteinG': prot,
                      'carbsG': carb,
                      'fatG': fat,
                    });
                    _reloadMeals();
                    if (mounted) showSnack(context, 'Logged $servings x ${food.name}');
                  },
                  child: const Text('Add to Daily Meal Log'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
