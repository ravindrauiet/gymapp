import 'package:fitkey_core/fitkey_core.dart' show formatNumber;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/session.dart';
import '../../ui/ui.dart';
import 'log_sheets.dart' show HealthSheetHeader;

/// Adds today's step count (from the member's phone step counter) to their FITKEY report.
/// Pops with `true` when saved.
class StepSyncSheet extends StatefulWidget {
  const StepSyncSheet({super.key});

  @override
  State<StepSyncSheet> createState() => _StepSyncSheetState();
}

class _StepSyncSheetState extends State<StepSyncSheet> {
  static const _sources = [
    ('health_connect', 'Health Connect', Icons.favorite_rounded),
    ('google_fit', 'Google Fit', Icons.directions_walk_rounded),
    ('apple_healthkit', 'Apple Health', Icons.monitor_heart_rounded),
    ('manual', 'Manual', Icons.edit_rounded),
  ];
  static const _goal = 10000;

  String _source = 'health_connect';
  final _steps = TextEditingController();
  bool _syncing = false;
  bool _loadingToday = true;
  int _savedToday = 0;
  String? _error;

  int get _value => int.tryParse(_steps.text) ?? 0;

  @override
  void initState() {
    super.initState();
    _loadToday();
  }

  Future<void> _loadToday() async {
    try {
      final today = await context.read<Session>().api.todaySteps();
      final steps = num.tryParse('${today['steps'] ?? 0}')?.toInt() ?? 0;
      final source = today['source']?.toString();
      if (!mounted) return;
      setState(() {
        _savedToday = steps;
        if (steps > 0 && _steps.text.isEmpty) _steps.text = '$steps';
        if (_sources.any((s) => s.$1 == source)) _source = source!;
      });
    } catch (_) {
      // Prefill is a convenience only — the sheet still works without it.
    } finally {
      if (mounted) setState(() => _loadingToday = false);
    }
  }

  Future<void> _sync() async {
    final steps = _value;
    if (steps <= 0 || steps > 100000) {
      setState(() => _error = 'Enter a step count between 1 and 1,00,000');
      return;
    }
    final api = context.read<Session>().api;
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      await api.syncSteps(
        steps: steps,
        distanceKm: double.parse((steps * 0.00075).toStringAsFixed(2)),
        activeCalories: (steps * 0.04).round(),
        source: _source,
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      toast(context, '$steps steps added to today', icon: Icons.directions_walk_rounded);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _syncing = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  void dispose() {
    _steps.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final steps = _value;
    final distanceKm = steps * 0.00075;
    final burn = (steps * 0.04).round();
    final progress = (steps / _goal).clamp(0.0, 1.0);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const HealthSheetHeader(
              icon: Icons.directions_walk_rounded,
              color: AppColors.amber,
              title: "Today's steps",
              subtitle: "Check your phone's step counter and add today's total",
            ),
            const SizedBox(height: 18),
            const Text('Counted by', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
            const SizedBox(height: 10),
            ChoiceChips<String>(
              padding: EdgeInsets.zero,
              options: [for (final s in _sources) s.$1],
              selected: _source,
              onSelected: (v) => setState(() => _source = v),
              label: (v) => _sources.firstWhere((s) => s.$1 == v).$2,
              icon: (v) => _sources.firstWhere((s) => s.$1 == v).$3,
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: AppColors.amberSoft, borderRadius: BorderRadius.circular(20)),
              child: Column(children: [
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: Stack(alignment: Alignment.center, children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 7,
                          strokeCap: StrokeCap.round,
                          backgroundColor: Colors.white,
                          valueColor: const AlwaysStoppedAnimation(AppColors.amber),
                        ),
                      ),
                      Text('${(progress * 100).round()}%',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                    ]),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      TextField(
                        controller: _steps,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                        onChanged: (_) => setState(() => _error = null),
                        style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -1),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          hintText: _loadingToday ? '…' : '8000',
                          hintStyle: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: AppColors.text3),
                        ),
                      ),
                      Text('steps · goal ${formatNumber(_goal)}',
                          style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600, fontSize: 12.5)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 8),
                Slider(
                  value: steps.clamp(0, 30000).toDouble(),
                  max: 30000,
                  divisions: 60,
                  activeColor: AppColors.amber,
                  inactiveColor: Colors.white,
                  onChanged: (v) => setState(() {
                    _steps.text = '${v.round()}';
                    _error = null;
                  }),
                ),
                Row(children: [
                  Expanded(child: _Estimate(icon: Icons.route_rounded, value: '${distanceKm.toStringAsFixed(2)} km', label: 'Distance')),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _Estimate(icon: Icons.local_fire_department_rounded, value: '$burn kcal', label: 'Active burn')),
                ]),
              ]),
            ),
            const SizedBox(height: 10),
            Text(
              _savedToday > 0
                  ? 'Already saved today: $_savedToday steps. Saving again replaces today\'s total.'
                  : 'Distance and burn are estimated from your steps.',
              style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w500),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: AppColors.redSoft, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  const Icon(Icons.error_outline_rounded, color: AppColors.red, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!,
                        style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 18),
            AppButton(label: 'Save steps', icon: Icons.sync_rounded, busy: _syncing, onPressed: _sync),
          ],
        ),
      ),
    );
  }
}

class _Estimate extends StatelessWidget {
  const _Estimate({required this.icon, required this.value, required this.label});
  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(icon, color: AppColors.amber, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            Text(label, style: const TextStyle(color: AppColors.text2, fontSize: 11.5, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }
}
