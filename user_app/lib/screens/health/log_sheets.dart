import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../state/session.dart';

/// Opens the "Log workout" sheet. Returns true if something was saved.
Future<bool> showActivitySheet(BuildContext context, {String initialType = 'workout'}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ActivitySheet(initialType: initialType),
  );
  return saved == true;
}

/// Opens the "Log weight" sheet. Returns true if saved.
Future<bool> showWeightSheet(BuildContext context, {double? current}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _WeightSheet(current: current),
  );
  return saved == true;
}

final _decimal = FilteringTextInputFormatter.allow(RegExp(r'^\d{0,4}(\.\d{0,2})?'));

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

  bool get _hasDistance => const {'running', 'cycling', 'swimming'}.contains(_type);

  Future<void> _save() async {
    final minutes = int.tryParse(_minutes.text);
    final distance = double.tryParse(_distance.text);
    if (minutes == null && distance == null) {
      return showSnack(context, 'Add a duration or distance', error: true);
    }
    setState(() => _saving = true);
    try {
      await context.read<Session>().api.logActivity({
        'type': _type,
        if (_title.text.trim().isNotEmpty) 'title': _title.text.trim(),
        'durationMin': ?minutes,
        if (_hasDistance && distance != null) 'distanceKm': distance,
        'calories': ?int.tryParse(_calories.text),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        showSnack(context, errorMessage(e), error: true);
        setState(() => _saving = false);
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
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Log activity', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: activityTypes.entries.map((e) {
                final selected = e.key == _type;
                return ChoiceChip(
                  selected: selected,
                  avatar: Icon(e.value.icon, size: 16, color: selected ? Colors.black : e.value.color),
                  label: Text(e.value.label, style: TextStyle(color: selected ? Colors.black : null)),
                  onSelected: (_) => setState(() => _type = e.key),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            TextField(controller: _title, decoration: const InputDecoration(hintText: 'Title (optional) — e.g. Leg day')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _minutes,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(hintText: 'Minutes', suffixText: 'min'),
                ),
              ),
              if (_hasDistance) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _distance,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [_decimal],
                    decoration: const InputDecoration(hintText: 'Distance', suffixText: 'km'),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _calories,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(hintText: 'Calories (optional)', suffixText: 'kcal'),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
          ],
        ),
      ),
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

  Future<void> _save() async {
    final kg = double.tryParse(_weight.text);
    if (kg == null || kg < 20 || kg > 400) return showSnack(context, 'Enter a weight between 20 and 400 kg', error: true);
    setState(() => _saving = true);
    try {
      await context.read<Session>().api.logWeight(kg);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        showSnack(context, errorMessage(e), error: true);
        setState(() => _saving = false);
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
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Today\'s weight', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _weight,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [_decimal],
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
            decoration: const InputDecoration(hintText: '70.0', suffixText: 'kg'),
          ),
          const SizedBox(height: 8),
          const Text('Tip: weigh yourself at the same time each day.',
              textAlign: TextAlign.center, style: TextStyle(color: FkColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 20),
          FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
        ],
      ),
    );
  }
}
