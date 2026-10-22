import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'ai_food_scanner.dart';
import 'fuel_log_screen.dart' show showFoodLogSheet;

/// Barcode scanner for packaged foods: scan (or type) an EAN/UPC code, see the
/// nutrition facts and log it — or register a new product from its label.
/// Pops with `true` when a meal was logged.
class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key, this.defaultMealType = 'breakfast'});

  final String defaultMealType;

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> with SingleTickerProviderStateMixin {
  final MobileScannerController _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  late final AnimationController _line =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat(reverse: true);

  /// True while a lookup or a result sheet is in progress — ignores further detections.
  bool _busy = false;
  bool _looking = false;

  static const _popular = [
    (label: 'Yoga Bar Protein Bar', code: '8908001150456'),
    (label: 'Epigamia Greek Yogurt', code: '8901030890123'),
    (label: 'MuscleBlaze Muesli', code: '8906067020012'),
    (label: 'Amul Protein Lassi', code: '8904223800010'),
    (label: 'ON Gold Standard Whey', code: '0748927028669'),
    (label: 'MyFitness Peanut Butter', code: '8901725181234'),
  ];

  @override
  void dispose() {
    _line.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    final code = capture.barcodes.firstOrNull?.rawValue?.trim();
    if (code == null || code.isEmpty) return;
    _handleBarcode(code);
  }

  Future<void> _handleBarcode(String code) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _looking = true;
    });
    HapticFeedback.mediumImpact();
    try {
      final res = await context.read<Session>().api.lookupBarcode(code);
      if (!mounted) return;
      setState(() => _looking = false);
      if (res.found && res.food != null) {
        await _logFood(res.food!, eyebrow: 'Product found');
      } else {
        final food = await showAppSheet<FoodItem>(context, builder: (_) => _RegisterFoodSheet(barcode: code));
        if (!mounted) return;
        if (food != null) await _logFood(food, eyebrow: 'Product added');
      }
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _looking = false;
        });
      }
    }
  }

  Future<void> _logFood(FoodItem food, {required String eyebrow}) async {
    final logged = await showFoodLogSheet(context, food, mealType: widget.defaultMealType, eyebrow: eyebrow);
    if (logged && mounted) Navigator.pop(context, true);
  }

  Future<void> _manualEntry() async {
    final code = await showAppSheet<String>(context, builder: (_) => const _ManualCodeSheet());
    if (code != null && code.isNotEmpty && mounted) _handleBarcode(code);
  }

  Future<void> _openAi() async {
    final logged = await push<bool>(context, AiFoodScannerScreen(defaultMealType: widget.defaultMealType));
    if (logged == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          systemOverlayStyle: SystemUiOverlayStyle.light,
          title: const Text('Scan barcode', style: TextStyle(color: Colors.white)),
          actions: [
            ValueListenableBuilder<MobileScannerState>(
              valueListenable: _controller,
              builder: (_, state, _) {
                if (state.torchState == TorchState.unavailable) return const SizedBox.shrink();
                final on = state.torchState == TorchState.on;
                return IconButton(
                  tooltip: on ? 'Torch off' : 'Torch on',
                  onPressed: () => _controller.toggleTorch(),
                  icon: Icon(on ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                      color: on ? AppColors.amber : Colors.white),
                );
              },
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(children: [
          Expanded(
            child: LayoutBuilder(builder: (context, c) {
              final w = (c.maxWidth - 64).clamp(200.0, 340.0);
              final window = Rect.fromCenter(
                center: Offset(c.maxWidth / 2, c.maxHeight / 2 + 20),
                width: w,
                height: w * 0.62,
              );
              return Stack(fit: StackFit.expand, children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  scanWindow: window,
                  errorBuilder: (context, error) => _CameraError(onManual: _manualEntry),
                ),
                IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _line,
                    builder: (_, _) => CustomPaint(painter: _ScanOverlayPainter(window: window, t: _line.value)),
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  top: window.bottom + 22,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _looking
                        ? const _Pill(key: ValueKey('l'), busy: true, text: 'Looking up nutrition…')
                        : const _Pill(key: ValueKey('h'), text: 'Point at the barcode on the pack'),
                  ),
                ),
              ]);
            }),
          ),
          _BottomPanel(
            busy: _busy,
            popular: _popular,
            onPopular: _handleBarcode,
            onManual: _manualEntry,
            onAi: _openAi,
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Camera overlay
// ---------------------------------------------------------------------------

class _ScanOverlayPainter extends CustomPainter {
  _ScanOverlayPainter({required this.window, required this.t});
  final Rect window;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(window, const Radius.circular(22));
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(rrect);
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.55));

    // Corner brackets
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const l = 30.0;
    const r = 22.0;
    final w = window;
    void corner(Offset o, double sx, double sy) {
      final path = Path()
        ..moveTo(o.dx, o.dy + sy * l)
        ..lineTo(o.dx, o.dy + sy * r)
        ..arcToPoint(Offset(o.dx + sx * r, o.dy), radius: const Radius.circular(r), clockwise: sx * sy > 0)
        ..lineTo(o.dx + sx * l, o.dy);
      canvas.drawPath(path, p);
    }

    corner(w.topLeft, 1, 1);
    corner(w.topRight, -1, 1);
    corner(w.bottomLeft, 1, -1);
    corner(w.bottomRight, -1, -1);

    // Animated scan line
    final y = w.top + 14 + (w.height - 28) * t;
    final line = Rect.fromLTWH(w.left + 18, y - 1.5, w.width - 36, 3);
    canvas.drawRRect(
      RRect.fromRectAndRadius(line.inflate(6), const Radius.circular(6)),
      Paint()
        ..color = AppColors.primary.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(line, const Radius.circular(2)),
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x00FF5A36), AppColors.primary, Color(0x00FF5A36)],
        ).createShader(line),
    );
  }

  @override
  bool shouldRepaint(_ScanOverlayPainter old) => old.t != t || old.window != window;
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.text, this.busy = false});
  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(30)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (busy) ...[
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
            const SizedBox(width: 10),
          ] else ...[
            const Icon(Icons.qr_code_2_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
          ],
          Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
        ]),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.onManual});
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.ink,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.no_photography_outlined, color: Colors.white, size: 44),
            const SizedBox(height: 14),
            const Text('Camera unavailable',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('Allow camera access in settings, or type the barcode digits instead.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.7), height: 1.4)),
            const SizedBox(height: 18),
            SizedBox(
              width: 200,
              child: AppButton(label: 'Type the code', icon: Icons.keyboard_rounded, onPressed: onManual, height: 48),
            ),
          ]),
        ),
      ),
    );
  }
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({
    required this.busy,
    required this.popular,
    required this.onPopular,
    required this.onManual,
    required this.onAi,
  });
  final bool busy;
  final List<({String label, String code})> popular;
  final ValueChanged<String> onPopular;
  final VoidCallback onManual;
  final VoidCallback onAi;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : onManual,
                icon: const Icon(Icons.keyboard_rounded, size: 20),
                label: const Text('Type code'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), backgroundColor: AppColors.ink),
                onPressed: busy ? null : onAi,
                icon: const Icon(Icons.auto_awesome_rounded, size: 20),
                label: const Text('Snap with AI'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          const Text('Popular packaged foods',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: AppColors.text)),
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: popular.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => Tap(
                onTap: busy ? null : () => onPopular(popular[i].code),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    const Icon(Icons.qr_code_rounded, size: 15, color: AppColors.text2),
                    const SizedBox(width: 6),
                    Text(popular[i].label,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: AppColors.text)),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Manual entry
// ---------------------------------------------------------------------------

class _ManualCodeSheet extends StatefulWidget {
  const _ManualCodeSheet();

  @override
  State<_ManualCodeSheet> createState() => _ManualCodeSheetState();
}

class _ManualCodeSheetState extends State<_ManualCodeSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _ctrl.text.trim();
    if (code.length < 4) {
      toast(context, 'Enter the full barcode number', error: true);
      return;
    }
    Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          IconBubble(Icons.dialpad_rounded, color: AppColors.blue),
          SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Enter barcode', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
              Text('The digits printed under the bars', style: TextStyle(color: AppColors.text2, fontSize: 13)),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        TextField(
          controller: _ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(14)],
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 2),
          decoration: const InputDecoration(hintText: '8908001150456', prefixIcon: Icon(Icons.qr_code_rounded)),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        AppButton(label: 'Look up nutrition', icon: Icons.search_rounded, onPressed: _submit),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Register an unknown product
// ---------------------------------------------------------------------------

class _RegisterFoodSheet extends StatefulWidget {
  const _RegisterFoodSheet({required this.barcode});
  final String barcode;

  @override
  State<_RegisterFoodSheet> createState() => _RegisterFoodSheetState();
}

class _RegisterFoodSheetState extends State<_RegisterFoodSheet> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _serving = TextEditingController(text: '1 serving');
  final _category = TextEditingController(text: 'Packaged Food');
  final _cal = TextEditingController();
  final _pro = TextEditingController();
  final _carb = TextEditingController();
  final _fat = TextEditingController();

  bool _saving = false;
  bool _reading = false;
  Set<TextEditingController> _highlight = {};

  @override
  void dispose() {
    for (final c in [_name, _serving, _category, _cal, _pro, _carb, _fat]) {
      c.dispose();
    }
    super.dispose();
  }

  String _num(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

  Future<void> _chooseSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const IconBubble(Icons.photo_camera_rounded, size: 40),
            title: const Text('Take a photo', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Snap the nutrition facts panel'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const IconBubble(Icons.photo_library_rounded, color: AppColors.purple, size: 40),
            title: const Text('Choose from gallery', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Use a photo you already took'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (source != null && mounted) _readLabel(source);
  }

  Future<void> _readLabel(ImageSource source) async {
    try {
      final file = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 85);
      if (file == null || !mounted) return;
      setState(() => _reading = true);
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final f = await context.read<Session>().api.extractNutritionFromImage(base64Encode(bytes), mode: 'label');
      if (!mounted) return;
      final filled = <TextEditingController>{};
      void set(TextEditingController c, String v) {
        if (v.trim().isEmpty) return;
        c.text = v;
        filled.add(c);
      }

      if (f.name.trim().isNotEmpty && f.name != 'Food') set(_name, f.name);
      set(_serving, f.servingUnit);
      if (f.category.trim().isNotEmpty && f.category != 'General') set(_category, f.category);
      set(_cal, '${f.calories}');
      set(_pro, _num(f.proteinG));
      set(_carb, _num(f.carbsG));
      set(_fat, _num(f.fatG));
      setState(() {
        _reading = false;
        _highlight = filled;
      });
      HapticFeedback.mediumImpact();
      toast(context, 'Label read — check the values and save', icon: Icons.auto_awesome_rounded);
      Future.delayed(const Duration(milliseconds: 1800), () {
        if (mounted) setState(() => _highlight = {});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _reading = false);
      toast(context, "Couldn't read that label. ${friendlyError(e)}", error: true);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final food = await context.read<Session>().api.registerBarcodeFood({
        'barcode': widget.barcode,
        'name': _name.text.trim(),
        'servingUnit': _serving.text.trim().isEmpty ? '1 serving' : _serving.text.trim(),
        'category': _category.text.trim().isEmpty ? 'Packaged Food' : _category.text.trim(),
        'calories': double.parse(_cal.text.trim()).round(),
        'proteinG': double.tryParse(_pro.text.trim()) ?? 0.0,
        'carbsG': double.tryParse(_carb.text.trim()) ?? 0.0,
        'fatG': double.tryParse(_fat.text.trim()) ?? 0.0,
      });
      if (mounted) Navigator.pop(context, food);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast(context, friendlyError(e), error: true);
    }
  }

  String? _required(String? v) => (v == null || v.trim().length < 2) ? 'Enter the product name' : null;

  String? _number(String? v, {bool required = false}) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return required ? 'Required' : null;
    final n = double.tryParse(t);
    if (n == null || n < 0) return 'Invalid';
    return null;
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? suffix,
    bool numeric = false,
    String? Function(String?)? validator,
  }) {
    final hl = _highlight.contains(c);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: hl ? [BoxShadow(color: AppColors.green.withValues(alpha: 0.35), blurRadius: 12)] : null,
      ),
      child: TextFormField(
        controller: c,
        enabled: !_reading,
        keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        textCapitalization: numeric ? TextCapitalization.none : TextCapitalization.words,
        inputFormatters: numeric ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))] : null,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffix,
          fillColor: hl ? AppColors.greenSoft : AppColors.surface,
          suffixIcon: hl ? const Icon(Icons.auto_awesome_rounded, color: AppColors.green, size: 18) : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const IconBubble(Icons.inventory_2_rounded, color: AppColors.amber, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('New product', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                const SizedBox(height: 4),
                Tag('Barcode ${widget.barcode}', color: AppColors.text2, icon: Icons.qr_code_rounded, dense: true),
              ]),
            ),
          ]),
          const SizedBox(height: 10),
          const Text(
            "We don't have this one yet. Add it once from the label — it will be ready for everyone next time.",
            style: TextStyle(color: AppColors.text2, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          _reading ? const _ReadingCard() : _AutoFillCard(onTap: _saving ? null : _chooseSource),
          const SizedBox(height: 18),
          _field(_name, 'Product / brand name', validator: _required),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _field(_serving, 'Serving size')),
            const SizedBox(width: 10),
            Expanded(child: _field(_category, 'Category')),
          ]),
          const SizedBox(height: 12),
          const Text('Per serving', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: _field(_cal, 'Calories', suffix: 'kcal', numeric: true, validator: (v) => _number(v, required: true))),
            const SizedBox(width: 10),
            Expanded(child: _field(_pro, 'Protein', suffix: 'g', numeric: true, validator: _number)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _field(_carb, 'Carbs', suffix: 'g', numeric: true, validator: _number)),
            const SizedBox(width: 10),
            Expanded(child: _field(_fat, 'Fat', suffix: 'g', numeric: true, validator: _number)),
          ]),
          const SizedBox(height: 20),
          AppButton(
            label: 'Save & continue',
            icon: Icons.check_rounded,
            busy: _saving,
            onPressed: _reading ? null : _save,
          ),
        ]),
      ),
    );
  }
}

class _AutoFillCard extends StatelessWidget {
  const _AutoFillCard({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: AppColors.mansiGradient,
          borderRadius: BorderRadius.circular(18),
          boxShadow: AppShadows.glow(AppColors.purple),
        ),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.document_scanner_rounded, color: Colors.white),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Auto-fill from label photo',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
              SizedBox(height: 2),
              Text('AI reads the nutrition facts for you',
                  style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w500)),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: Colors.white),
        ]),
      ),
    );
  }
}

class _ReadingCard extends StatelessWidget {
  const _ReadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.purpleSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(children: [
        const SizedBox(
          width: 44,
          height: 44,
          child: Padding(
            padding: EdgeInsets.all(10),
            child: CircularProgressIndicator(strokeWidth: 2.6, color: AppColors.purple),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Reading label…',
                style: TextStyle(color: AppColors.purple, fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 8),
            Shimmer(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SkeletonBox(height: 10, width: 180, radius: 6),
                const SizedBox(height: 6),
                SkeletonBox(height: 10, width: 120, radius: 6),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}
