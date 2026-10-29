import 'package:fitkey_core/fitkey_core.dart' show formatNumber;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/progress_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'health_sync.dart';
import 'log_sheets.dart' show HealthSheetHeader;

/// Steps for the member's FITKEY report: auto-sync from Health Connect (Android) / Apple Health (iOS),
/// with manual entry as the fallback (and on web). Pops with `true` when something was saved.
class StepSyncSheet extends StatefulWidget {
  const StepSyncSheet({super.key, this.goal = 8000});

  /// The member's daily steps goal.
  final int goal;

  @override
  State<StepSyncSheet> createState() => _StepSyncSheetState();
}

class _StepSyncSheetState extends State<StepSyncSheet> {
  final _sync = HealthSync.instance;
  HealthSyncState? _state;
  bool _autoBusy = false;

  final _steps = TextEditingController();
  bool _saving = false;
  bool _loadingToday = true;
  int _savedToday = 0;
  String? _error;

  int get _goal => widget.goal;
  int get _value => int.tryParse(_steps.text) ?? 0;

  @override
  void initState() {
    super.initState();
    _loadToday();
    _loadState();
  }

  Future<void> _loadState() async {
    final st = await _sync.state();
    if (mounted) setState(() => _state = st);
  }

  Future<void> _loadToday() async {
    try {
      final today = await context.read<Session>().api.todaySteps();
      final steps = num.tryParse('${today['steps'] ?? 0}')?.toInt() ?? 0;
      if (!mounted) return;
      setState(() {
        _savedToday = steps;
        if (steps > 0 && _steps.text.isEmpty) _steps.text = '$steps';
      });
    } catch (_) {
      // Prefill is a convenience only — the sheet still works without it.
    } finally {
      if (mounted) setState(() => _loadingToday = false);
    }
  }

  Future<void> _autoSync() async {
    final api = context.read<Session>().api;
    setState(() {
      _autoBusy = true;
      _error = null;
    });
    try {
      if (_state != HealthSyncState.connected) {
        final granted = await _sync.connect();
        if (!granted) {
          if (!mounted) return;
          setState(() {
            _autoBusy = false;
            _error = 'Permission not granted. You can still add steps manually below.';
          });
          return;
        }
      }
      final days = await _sync.syncRecent(api, days: 30);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _autoBusy = false;
        _state = HealthSyncState.connected;
      });
      if (days == 0) {
        toast(context, 'Connected — no steps recorded on this phone yet', icon: Icons.sync_rounded);
      } else {
        toast(context, 'Synced $days day${days == 1 ? '' : 's'} of steps', icon: Icons.sync_rounded);
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _autoBusy = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _saveManual() async {
    final steps = _value;
    if (steps <= 0 || steps > 100000) {
      setState(() => _error = 'Enter a step count between 1 and 1,00,000');
      return;
    }
    final api = context.read<Session>().api;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await api.saveManualSteps(steps);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      toast(context, '$steps steps added to today', icon: Icons.directions_walk_rounded);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
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
    final progress = _goal > 0 ? (steps / _goal).clamp(0.0, 1.0) : 0.0;

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
              subtitle: 'Sync automatically from your phone, or add them yourself',
            ),
            const SizedBox(height: 18),
            _AutoSyncCard(
              state: _state,
              provider: _sync.providerName,
              busy: _autoBusy,
              onSync: _autoSync,
              onInstall: () async {
                await _sync.installHealthConnect();
                if (mounted) _loadState();
              },
            ),
            const SizedBox(height: 18),
            const Text('Or add manually', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
            const SizedBox(height: 10),
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
                          backgroundColor: AppColors.surface,
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
                  inactiveColor: AppColors.surface,
                  onChanged: (v) => setState(() {
                    _steps.text = '${v.round()}';
                    _error = null;
                  }),
                ),
                Row(children: [
                  Expanded(
                      child: _Estimate(
                          icon: Icons.route_rounded, value: '${distanceKm.toStringAsFixed(2)} km', label: 'Distance')),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _Estimate(icon: Icons.local_fire_department_rounded, value: '$burn kcal', label: 'Active burn')),
                ]),
              ]),
            ),
            const SizedBox(height: 10),
            Text(
              _savedToday > 0
                  ? 'Already saved today: ${formatNumber(_savedToday)} steps. Saving again replaces today\'s total.'
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
            AppButton(label: 'Save steps', icon: Icons.check_rounded, busy: _saving, onPressed: _saveManual),
          ],
        ),
      ),
    );
  }
}

class _AutoSyncCard extends StatelessWidget {
  const _AutoSyncCard({
    required this.state,
    required this.provider,
    required this.busy,
    required this.onSync,
    required this.onInstall,
  });
  final HealthSyncState? state;
  final String provider;
  final bool busy;
  final VoidCallback onSync;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final (String title, String body, String? cta, VoidCallback? action, IconData icon) = switch (state) {
      null => ('Checking $provider…', 'One moment', null, null, Icons.sync_rounded),
      HealthSyncState.unsupported => (
          'Auto-sync is available in the mobile app',
          'Open FITKEY on your Android phone or iPhone to sync steps from Health Connect or Apple Health.',
          null,
          null,
          Icons.phone_android_rounded,
        ),
      HealthSyncState.notInstalled => (
          'Install Health Connect',
          'Health Connect lets FITKEY read your steps, distance and active calories automatically.',
          'Get it on Play Store',
          onInstall,
          Icons.download_rounded,
        ),
      HealthSyncState.needsPermission => (
          'Connect $provider',
          'Allow read access once — steps, distance and active calories then sync automatically.',
          'Connect',
          onSync,
          Icons.link_rounded,
        ),
      HealthSyncState.connected => (
          '$provider connected',
          'Steps sync automatically when you open Progress. Tap to sync the last 30 days now.',
          'Sync now',
          onSync,
          Icons.check_circle_rounded,
        ),
    };
    final connected = state == HealthSyncState.connected;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: connected ? AppColors.greenSoft : AppColors.blueSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconBubble(icon, color: connected ? AppColors.green : AppColors.blue, bg: AppColors.surface, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
              const SizedBox(height: 2),
              Text(body, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
            ]),
          ),
        ]),
        if (cta != null) ...[
          const SizedBox(height: 12),
          AppButton(label: cta, icon: Icons.sync_rounded, busy: busy, onPressed: action),
        ],
      ]),
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
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
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
