import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/session.dart';
import '../../ui/ui.dart';

/// Opens the "Log workout" sheet. Returns true if something was saved.
Future<bool> showActivitySheet(BuildContext context, {String initialType = 'workout'}) async {
  final saved = await showAppSheet<bool>(context, builder: (_) => _ActivitySheet(initialType: initialType));
  return saved == true;
}

/// Opens the "Log weight" sheet. Returns true if saved.
Future<bool> showWeightSheet(BuildContext context, {double? current}) async {
  final saved = await showAppSheet<bool>(context, builder: (_) => _WeightSheet(current: current));
  return saved == true;
}

final _decimal = FilteringTextInputFormatter.allow(RegExp(r'^\d{0,4}(\.\d{0,2})?'));

/// Sheet heading: icon bubble + title + subtitle.
class HealthSheetHeader extends StatelessWidget {
  const HealthSheetHeader({super.key, required this.icon, required this.color, required this.title, this.subtitle});

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      IconBubble(icon, color: color, size: 46),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: const TextStyle(color: AppColors.text2, fontSize: 13, fontWeight: FontWeight.w500)),
          ],
        ]),
      ),
    ]);
  }
}

/// Large number entry box — "45 min", "5.2 km".
class _BigNumberField extends StatelessWidget {
  const _BigNumberField({
    required this.controller,
    required this.label,
    required this.unit,
    this.decimal = false,
    this.hint = '0',
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String unit;
  final bool decimal;
  final String hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(),
            style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: AppColors.text3, letterSpacing: 1.2)),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              keyboardType: decimal ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.number,
              inputFormatters: [decimal ? _decimal : FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(7)],
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5),
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintStyle: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: AppColors.text3),
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
              ),
            ),
          ),
          Text(unit, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.text2)),
        ]),
      ]),
    );
  }
}

class _ActivitySheet extends StatefulWidget {
  const _ActivitySheet({required this.initialType});

  final String initialType;

  @override
  State<_ActivitySheet> createState() => _ActivitySheetState();
}

class _ActivitySheetState extends State<_ActivitySheet> {
  late String _type = widget.initialType;
  final _title = TextEditingController();
  final _minutes = TextEditingController();
  final _distance = TextEditingController();
  final _calories = TextEditingController();
  bool _saving = false;
  String? _error;

  bool get _hasDistance => const {'running', 'cycling', 'swimming'}.contains(_type);

  Future<void> _save() async {
    final minutes = int.tryParse(_minutes.text);
    final distance = _hasDistance ? double.tryParse(_distance.text) : null;
    final calories = int.tryParse(_calories.text);
    String? error;
    if ((minutes == null || minutes == 0) && (distance == null || distance == 0)) {
      error = _hasDistance ? 'Add how long or how far you went' : 'Add how many minutes you trained';
    } else if (minutes != null && minutes > 1440) {
      error = 'Duration can be at most 1440 minutes';
    } else if (distance != null && distance > 500) {
      error = 'Distance can be at most 500 km';
    } else if (calories != null && calories > 20000) {
      error = 'Calories look too high — max 20,000 kcal';
    }
    setState(() => _error = error);
    if (error != null) return;

    setState(() => _saving = true);
    try {
      await context.read<Session>().api.logActivity({
        'type': _type,
        if (_title.text.trim().isNotEmpty) 'title': _title.text.trim(),
        'durationMin': ?minutes,
        'distanceKm': ?distance,
        'calories': ?calories,
      });
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _minutes.dispose();
    _distance.dispose();
    _calories.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final types = activityVisuals.toList();
    final current = activityVisual(_type);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HealthSheetHeader(
              icon: current.icon,
              color: current.color,
              title: 'Log activity',
              subtitle: 'Every session counts towards your report',
            ),
            const SizedBox(height: 20),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.92,
              children: [
                for (final e in types)
                  Tap(
                    onTap: () => setState(() {
                      _type = e.key;
                      _error = null;
                    }),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      decoration: BoxDecoration(
                        color: e.key == _type ? e.value.soft : AppColors.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: e.key == _type ? e.value.color : AppColors.line, width: e.key == _type ? 1.6 : 1),
                      ),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(e.value.icon, color: e.value.color, size: 26),
                        const SizedBox(height: 6),
                        Text(e.value.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: e.key == _type ? FontWeight.w800 : FontWeight.w600,
                                color: e.key == _type ? AppColors.text : AppColors.text2)),
                      ]),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: _BigNumberField(
                  controller: _minutes,
                  label: 'Duration',
                  unit: 'min',
                  hint: '45',
                  onChanged: (_) => setState(() => _error = null),
                ),
              ),
              if (_hasDistance) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _BigNumberField(
                    controller: _distance,
                    label: 'Distance',
                    unit: 'km',
                    hint: '5.0',
                    decimal: true,
                    onChanged: (_) => setState(() => _error = null),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 10),
            _BigNumberField(controller: _calories, label: 'Calories (optional — auto-estimated)', unit: 'kcal', hint: '300'),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Add a note — e.g. Leg day',
                prefixIcon: Icon(Icons.edit_note_rounded),
                counterText: '',
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              child: _error == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _ErrorLine(_error!),
                    ),
            ),
            const SizedBox(height: 18),
            AppButton(
              label: 'Save ${current.label.toLowerCase()}',
              icon: Icons.check_rounded,
              busy: _saving,
              onPressed: _save,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: AppColors.redSoft, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.error_outline_rounded, color: AppColors.red, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      ]),
    );
  }
}

class _WeightSheet extends StatefulWidget {
  const _WeightSheet({this.current});

  final double? current;

  @override
  State<_WeightSheet> createState() => _WeightSheetState();
}

class _WeightSheetState extends State<_WeightSheet> {
  late final _weight = TextEditingController(text: widget.current?.toStringAsFixed(1));
  bool _saving = false;
  String? _error;

  void _nudge(double delta) {
    final v = (double.tryParse(_weight.text) ?? widget.current ?? 70) + delta;
    HapticFeedback.selectionClick();
    setState(() {
      _weight.text = v.clamp(20, 400).toStringAsFixed(1);
      _error = null;
    });
  }

  Future<void> _save() async {
    final kg = double.tryParse(_weight.text);
    if (kg == null || kg < 20 || kg > 400) {
      setState(() => _error = 'Enter a weight between 20 and 400 kg');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<Session>().api.logWeight(kg);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  void dispose() {
    _weight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kg = double.tryParse(_weight.text);
    final diff = (kg != null && widget.current != null) ? kg - widget.current! : null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const HealthSheetHeader(
              icon: Icons.monitor_weight_rounded,
              color: AppColors.blue,
              title: "Today's weight",
              subtitle: 'Weigh in at the same time each day for the truest trend',
            ),
            const SizedBox(height: 24),
            Row(children: [
              _RoundStep(icon: Icons.remove_rounded, onTap: () => _nudge(-0.1)),
              Expanded(
                child: Column(children: [
                  IntrinsicWidth(
                    child: TextField(
                      controller: _weight,
                      autofocus: widget.current == null,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [_decimal],
                      textAlign: TextAlign.center,
                      onChanged: (_) => setState(() => _error = null),
                      style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w800, letterSpacing: -1.5),
                      decoration: const InputDecoration(
                        isCollapsed: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: '70.0',
                        hintStyle: TextStyle(fontSize: 48, fontWeight: FontWeight.w800, color: AppColors.text3),
                      ),
                    ),
                  ),
                  const Text('kilograms', style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700)),
                ]),
              ),
              _RoundStep(icon: Icons.add_rounded, onTap: () => _nudge(0.1)),
            ]),
            const SizedBox(height: 14),
            if (diff != null && diff.abs() >= 0.05)
              Center(
                child: Tag(
                  '${diff > 0 ? '+' : ''}${diff.toStringAsFixed(1)} kg vs last log',
                  color: AppColors.blue,
                  icon: diff > 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                ),
              )
            else if (widget.current != null)
              Center(
                child: Text('Last logged: ${widget.current!.toStringAsFixed(1)} kg',
                    style: const TextStyle(color: AppColors.text3, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            if (_error != null) ...[const SizedBox(height: 12), _ErrorLine(_error!)],
            const SizedBox(height: 22),
            AppButton(label: 'Save weight', icon: Icons.check_rounded, busy: _saving, onPressed: _save),
          ],
        ),
      ),
    );
  }
}

class _RoundStep extends StatelessWidget {
  const _RoundStep({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      haptic: false,
      child: Container(
        width: 48,
        height: 48,
        decoration: const BoxDecoration(color: AppColors.surfaceAlt, shape: BoxShape.circle),
        child: Icon(icon, color: AppColors.text),
      ),
    );
  }
}
