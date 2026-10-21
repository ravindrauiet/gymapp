import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import 'ai_food_scanner.dart';

/// Barcode & Nutrition Scanner for Fuel Log.
/// Uses the device camera to scan UPC/EAN barcodes on packaged fitness foods,
/// looks up macro/micronutrient breakdown, and allows instant logging.
class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key, this.defaultMealType = 'breakfast'});

  final String defaultMealType;

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _isProcessing = false;
  bool _manualMode = false;
  final TextEditingController _manualInput = TextEditingController();

  final List<({String label, String code})> _sampleBarcodes = const [
    (label: 'Yoga Bar 20g Protein', code: '8908001150456'),
    (label: 'Epigamia Greek Yogurt', code: '8901030890123'),
    (label: 'MuscleBlaze Muesli', code: '8906067020012'),
    (label: 'Amul High Protein Lassi', code: '8904223800010'),
    (label: 'ON Gold Standard Whey', code: '0748927028669'),
    (label: 'MyFitness Peanut Butter', code: '8901725181234'),
  ];

  @override
  void dispose() {
    _controller.dispose();
    _manualInput.dispose();
    super.dispose();
  }

  Future<void> _handleBarcode(String code) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);
    HapticFeedback.mediumImpact();

    try {
      final res = await context.read<Session>().api.lookupBarcode(code);
      if (!mounted) return;

      if (res.found && res.food != null) {
        _showScannedFoodSheet(res.food!);
      } else {
        _showUnknownBarcodeDialog(code);
      }
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _onDetect(BarcodeCapture capture) {
    final barcode = capture.barcodes.firstOrNull?.rawValue;
    if (barcode == null || barcode.trim().isEmpty) return;
    _handleBarcode(barcode.trim());
  }

  void _showScannedFoodSheet(FoodItem food) {
    double servings = 1.0;
    String selectedMeal = widget.defaultMealType;

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
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(color: FkColors.lime, shape: BoxShape.circle),
                      child: const Icon(Icons.check, color: Colors.black, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Barcode Scanned!',
                            style: const TextStyle(color: FkColors.lime, fontWeight: FontWeight.bold, fontSize: 12)),
                        Text(food.name,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  Text('Serving Unit: ${food.servingUnit} · ${food.category}',
                      style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
                  const Divider(height: 24),

                  // Meal category selector
                  const Text('Select Meal Category', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: selectedMeal,
                    decoration: const InputDecoration(isDense: true),
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

                  // Servings slider
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

                  // Dynamic macros preview
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
                      final api = context.read<Session>().api;
                      final messenger = ScaffoldMessenger.of(context);
                      await api.logMeal({
                        'mealType': selectedMeal,
                        'foodId': food.id,
                        'foodName': food.name,
                        'servings': servings,
                        'calories': cals,
                        'proteinG': prot,
                        'carbsG': carb,
                        'fatG': fat,
                      });
                      messenger.showSnackBar(
                        SnackBar(content: Text('Logged ${servings}x ${food.name} to ${selectedMeal.toUpperCase()}')),
                      );
                      if (mounted) Navigator.pop(context, true);
                    },
                    child: const Text('Add to Fuel Log'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showUnknownBarcodeDialog(String barcode) {
    final nameCtrl = TextEditingController();
    final calCtrl = TextEditingController();
    final proCtrl = TextEditingController();
    final carbCtrl = TextEditingController();
    final fatCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Barcode Detected'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Barcode: $barcode', style: const TextStyle(color: FkColors.lime, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('This packaged food is not yet in the encyclopedia. Add its nutrition label info to log it:'),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.auto_awesome, color: FkColors.lime, size: 18),
                label: const Text('Snap Nutrition Label with AI'),
                onPressed: () async {
                  Navigator.pop(ctx);
                  final logged = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(builder: (_) => const AiFoodScannerScreen()),
                  );
                  if (logged == true && mounted) Navigator.pop(context, true);
                },
              ),
              const SizedBox(height: 12),
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Product / Brand Name')),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: calCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Calories (kcal)'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: proCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Protein (g)'))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: carbCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Carbs (g)'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: fatCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Fats (g)'))),
              ]),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final cals = int.tryParse(calCtrl.text) ?? 100;
              final p = double.tryParse(proCtrl.text) ?? 0.0;
              final c = double.tryParse(carbCtrl.text) ?? 0.0;
              final f = double.tryParse(fatCtrl.text) ?? 0.0;

              if (name.isEmpty) return;

              Navigator.pop(ctx);
              final api = context.read<Session>().api;
              final food = await api.registerBarcodeFood({
                'barcode': barcode,
                'name': name,
                'servingUnit': '1 serving',
                'calories': cals,
                'proteinG': p,
                'carbsG': c,
                'fatG': f,
              });

              _showScannedFoodSheet(food);
            },
            child: const Text('Save & Log'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Food Barcode'),
        actions: [
          IconButton(
            tooltip: 'AI Snap Food / Label',
            icon: const Icon(Icons.auto_awesome, color: FkColors.lime),
            onPressed: () async {
              final logged = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const AiFoodScannerScreen()),
              );
              if (logged == true && mounted) Navigator.pop(context, true);
            },
          ),
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            tooltip: _manualMode ? 'Camera' : 'Manual Code',
            icon: Icon(_manualMode ? Icons.qr_code_scanner : Icons.keyboard),
            onPressed: () => setState(() => _manualMode = !_manualMode),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _manualMode
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.dialpad, size: 54, color: FkColors.lime),
                        const SizedBox(height: 16),
                        const Text('Enter EAN / UPC Barcode Manually',
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        const SizedBox(height: 8),
                        const Text(
                          'Type the numeric digits printed underneath the packaged food barcode.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: FkColors.textSecondary, fontSize: 13),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: _manualInput,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            hintText: 'e.g. 8908001150456',
                            prefixIcon: Icon(Icons.qr_code),
                          ),
                          onSubmitted: (v) {
                            if (v.trim().isNotEmpty) _handleBarcode(v.trim());
                          },
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () {
                            final code = _manualInput.text.trim();
                            if (code.isNotEmpty) _handleBarcode(code);
                          },
                          child: const Text('Lookup Nutrition'),
                        ),
                      ],
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      MobileScanner(
                        controller: _controller,
                        onDetect: _onDetect,
                      ),
                      // Viewfinder overlay
                      Center(
                        child: Container(
                          width: 260,
                          height: 160,
                          decoration: BoxDecoration(
                            border: Border.all(color: FkColors.lime, width: 2.5),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(color: FkColors.lime.withValues(alpha: 0.25), blurRadius: 18),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 30,
                        left: 20,
                        right: 20,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'Align the barcode inside the frame to scan macros',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),

          // Quick simulator test pills (convenient for emulator & quick demo testing)
          Container(
            padding: const EdgeInsets.all(16),
            color: FkColors.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Row(children: [
                  Icon(Icons.bolt, color: FkColors.lime, size: 16),
                  SizedBox(width: 6),
                  Text('Quick Test Barcodes (Demo & Emulator)',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: FkColors.textSecondary)),
                ]),
                const SizedBox(height: 10),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _sampleBarcodes.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, idx) {
                      final item = _sampleBarcodes[idx];
                      return ActionChip(
                        label: Text(item.label),
                        avatar: const Icon(Icons.qr_code, size: 16),
                        onPressed: () => _handleBarcode(item.code),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
