import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../state/session.dart';

/// 4. Activity & Movement Tracking Engine
/// Native integration with Health Connect, Google Fit, and Apple HealthKit.
/// Distance covered in KM and active calories burned.
class StepSyncSheet extends StatefulWidget {
  const StepSyncSheet({super.key});

  @override
  State<StepSyncSheet> createState() => _StepSyncSheetState();
}

class _StepSyncSheetState extends State<StepSyncSheet> {
  String _source = 'health_connect'; // health_connect | google_fit | apple_healthkit
  int _simulatedSteps = 8450;
  bool _syncing = false;

  @override
  Widget build(BuildContext context) {
    final distanceKm = (_simulatedSteps * 0.00075).toStringAsFixed(2);
    final activeBurn = (_simulatedSteps * 0.04).round();

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.directions_walk, color: FkColors.lime, size: 28),
            const SizedBox(width: 10),
            Text('Sync Movement & Steps', style: Theme.of(context).textTheme.titleLarge),
          ]),
          const SizedBox(height: 6),
          const Text(
            'Sync your step counts and movement burn from your mobile health engine directly into your FITKEY Health Report.',
            style: TextStyle(color: FkColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 16),

          // Provider selector
          const Text('Select Health Engine Provider', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'health_connect', label: Text('Health Connect')),
              ButtonSegment(value: 'google_fit', label: Text('Google Fit')),
              ButtonSegment(value: 'apple_healthkit', label: Text('HealthKit')),
            ],
            selected: {_source},
            onSelectionChanged: (s) => setState(() => _source = s.first),
          ),
          const SizedBox(height: 16),

          // Live stats preview box
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: FkColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: FkColors.outline),
            ),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Detected Today\'s Steps', style: TextStyle(color: FkColors.textSecondary)),
                Text('$_simulatedSteps steps',
                    style: const TextStyle(fontWeight: FontWeight.w900, color: FkColors.lime, fontSize: 16)),
              ]),
              Slider(
                value: _simulatedSteps.toDouble(),
                min: 1000,
                max: 25000,
                divisions: 48,
                activeColor: FkColors.lime,
                onChanged: (v) => setState(() => _simulatedSteps = v.round()),
              ),
              const Divider(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                Column(children: [
                  const Text('Distance Covered', style: TextStyle(color: FkColors.textSecondary, fontSize: 11)),
                  const SizedBox(height: 2),
                  Text('$distanceKm KM', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: FkColors.sky)),
                ]),
                Column(children: [
                  const Text('Active Calories Burned', style: TextStyle(color: FkColors.textSecondary, fontSize: 11)),
                  const SizedBox(height: 2),
                  Text('$activeBurn kcal', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: FkColors.orange)),
                ]),
              ]),
            ]),
          ),
          const SizedBox(height: 24),

          FilledButton(
            onPressed: _syncing
                ? null
                : () async {
                    final api = context.read<Session>().api;
                    setState(() => _syncing = true);
                    try {
                      await api.syncSteps(
                        steps: _simulatedSteps,
                        distanceKm: double.parse(distanceKm),
                        activeCalories: activeBurn,
                        source: _source,
                      );
                      if (mounted) {
                        Navigator.pop(context, true);
                        showSnack(context, 'Synced $_simulatedSteps steps from ${_source.replaceAll('_', ' ')}!');
                      }
                    } catch (e) {
                      if (mounted) showSnack(context, errorMessage(e), error: true);
                    } finally {
                      if (mounted) setState(() => _syncing = false);
                    }
                  },
            child: _syncing
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Text('Sync with FITKEY Health Engine'),
          ),
        ],
      ),
    );
  }
}
