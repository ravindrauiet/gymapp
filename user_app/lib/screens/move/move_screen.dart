import 'dart:math' as math;

import 'package:fitkey_core/fitkey_core.dart' show formatNumber;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings, PermissionStatusGetters;
import 'package:provider/provider.dart';

import '../../data/activity_api.dart';
import '../../services/geo.dart';
import '../../services/move_tracker.dart';
import '../../services/step_counter.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'move_map.dart';

const _stepGoal = 8000;

IconData _modeIcon(MoveMode m) => switch (m) {
      MoveMode.walk => Icons.directions_walk_rounded,
      MoveMode.run => Icons.directions_run_rounded,
      MoveMode.cycle => Icons.directions_bike_rounded,
      MoveMode.travel => Icons.directions_car_rounded,
    };

Color _modeColor(MoveMode m) => switch (m) {
      MoveMode.walk => AppColors.green,
      MoveMode.run => AppColors.primary,
      MoveMode.cycle => AppColors.blue,
      MoveMode.travel => AppColors.purple,
    };

/// Move: today's steps, record a walk / run / ride / travel on a map, and the area you've explored.
class MoveScreen extends StatefulWidget {
  const MoveScreen({super.key});

  @override
  State<MoveScreen> createState() => _MoveScreenState();
}

class _MoveScreenState extends State<MoveScreen> {
  final _tracker = MoveTracker.instance;
  final _steps = StepCounter.instance;
  MoveMode _mode = MoveMode.walk;
  int _days = 30;
  List<MoveTrack>? _tracks;
  Object? _error;
  bool _starting = false;
  bool _saving = false;
  LatLng? _here;

  @override
  void initState() {
    super.initState();
    final api = context.read<Session>().api;
    _steps.start(api);
    _tracker.flushPending(api).then((n) {
      if (n > 0) _load();
    });
    _load();
    _locate();
  }

  Future<void> _locate() async {
    try {
      final p = await Geolocator.getLastKnownPosition();
      if (p != null && mounted) setState(() => _here = LatLng(p.latitude, p.longitude));
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final t = await context.read<Session>().api.tracks(days: _days);
      if (mounted) setState(() => _tracks = t);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _start() async {
    HapticFeedback.mediumImpact();
    setState(() => _starting = true);
    final err = await _tracker.start(_mode);
    if (!mounted) return;
    setState(() => _starting = false);
    if (err != null) {
      toast(context, err, error: true);
      if (err.contains('Settings')) await openAppSettings();
      if (err.contains('GPS')) await Geolocator.openLocationSettings();
    }
  }

  Future<void> _stop() async {
    HapticFeedback.mediumImpact();
    setState(() => _saving = true);
    try {
      final saved = await _tracker.stopAndSave(context.read<Session>().api);
      if (!mounted) return;
      if (saved == null) {
        toast(context, 'Too short to save — move at least 30 m next time.');
      } else {
        toast(context, '${saved.mode.label} saved · ${Geo.km(saved.distanceM)}', icon: Icons.check_circle_rounded);
        await _load();
        if (mounted) push(context, TrackDetailScreen(track: saved));
      }
    } catch (_) {
      if (mounted) toast(context, 'No internet — saved on your phone, it will upload automatically.', icon: Icons.cloud_off_rounded);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Discard this recording?'),
        content: const Text('The route and distance will not be saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep recording')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard')),
        ],
      ),
    );
    if (ok == true) await _tracker.discard();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_tracker, _steps]),
      builder: (context, _) => _tracker.recording ? _live() : _home(),
    );
  }

  // ------------------------------------------------------------------------------------------- live recording

  Widget _live() {
    final t = _tracker;
    final asSpeed = t.mode == MoveMode.cycle || t.mode == MoveMode.travel;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: MoveMap(paths: [t.points], cells: t.cells, current: t.current ?? _here, follow: true),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              _GlassPill(icon: _modeIcon(t.mode), label: 'Recording ${t.mode.label.toLowerCase()}', live: true),
              const Spacer(),
              if (t.accuracyM != null)
                _GlassPill(
                  icon: Icons.gps_fixed_rounded,
                  label: t.accuracyM! <= 20 ? 'GPS good' : (t.accuracyM! <= 35 ? 'GPS ok' : 'Weak GPS'),
                ),
            ]),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 16 + MediaQuery.paddingOf(context).bottom),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              boxShadow: [BoxShadow(color: Color(0x22000000), blurRadius: 20)],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(Geo.km(t.distanceM),
                  style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800, letterSpacing: -1.5, height: 1)),
              const SizedBox(height: 4),
              const Text('distance', style: TextStyle(color: AppColors.text3, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Row(children: [
                _LiveStat(label: 'Time', value: Geo.duration(t.elapsedS)),
                _LiveStat(label: asSpeed ? 'Avg speed' : 'Pace', value: Geo.pace(t.distanceM, math.max(1, t.movingS), asSpeed: asSpeed)),
                if (!asSpeed) _LiveStat(label: 'Steps', value: formatNumber(t.steps)),
                _LiveStat(label: 'Explored', value: Geo.area(t.areaM2)),
              ]),
              const SizedBox(height: 18),
              Row(children: [
                SizedBox(
                  width: 120,
                  child: AppButton(
                    label: 'Discard',
                    onPressed: _saving ? null : _discard,
                    color: AppColors.surfaceAlt,
                    foreground: AppColors.text,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AppButton(
                    label: 'Finish & save',
                    icon: Icons.stop_rounded,
                    busy: _saving,
                    onPressed: _stop,
                    color: AppColors.ink,
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              const Text('Keeps recording with the screen off.',
                  style: TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ]),
    );
  }

  // ------------------------------------------------------------------------------------------- home

  Widget _home() {
    final tracks = _tracks ?? const <MoveTrack>[];
    final paths = [for (final t in tracks) t.path];
    final cells = <(int, int)>{for (final p in paths) ...Geo.cellsOf(p)};
    final totalDist = tracks.fold<double>(0, (s, t) => s + t.distanceM);
    final byMode = <MoveMode, double>{};
    for (final t in tracks) {
      byMode[t.mode] = (byMode[t.mode] ?? 0) + t.distanceM;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Move')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            const StepsTodayCard(),
            const SizedBox(height: 14),
            _startCard(),
            SectionTitle(
              'Area you explored',
              subtitle: 'Every ~100 m square you walked, ran, rode or travelled through',
            ),
            _periodChips(),
            const SizedBox(height: 12),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: SizedBox(
                    height: 260,
                    child: _tracks == null && _error == null
                        ? const SkeletonBox(height: 260)
                        : MoveMap(paths: paths, cells: cells, fallbackCenter: _here),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    _BigStat(value: Geo.area(Geo.areaOf(cells)), label: 'explored'),
                    _BigStat(value: Geo.km(totalDist), label: 'covered'),
                    _BigStat(value: '${tracks.length}', label: tracks.length == 1 ? 'trip' : 'trips'),
                  ]),
                ),
                if (byMode.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final e in byMode.entries)
                        Tag('${e.key.label} ${Geo.km(e.value)}', color: _modeColor(e.key), icon: _modeIcon(e.key)),
                    ]),
                  ),
              ]),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: ErrorView(error: _error!, onRetry: _load),
              ),
            if (_tracks != null && tracks.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: EmptyView(
                  icon: Icons.map_rounded,
                  title: 'Your map is empty',
                  message: 'Start a walk, run, ride or trip above — your route and the area you cover will appear here.',
                ),
              ),
            if (tracks.isNotEmpty) ...[
              const SectionTitle('Recent trips'),
              for (final t in tracks) ...[
                _TrackTile(
                  track: t,
                  onTap: () async {
                    final deleted = await push<bool>(context, TrackDetailScreen(track: t));
                    if (deleted == true) _load();
                  },
                ),
                const SizedBox(height: 10),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _periodChips() => Row(children: [
        for (final d in const [7, 30, 90])
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(d == 7 ? 'This week' : '$d days'),
              selected: _days == d,
              onSelected: (_) {
                setState(() {
                  _days = d;
                  _tracks = null;
                });
                _load();
              },
            ),
          ),
      ]);

  Widget _startCard() {
    return AppCard(
      gradient: AppColors.passGradient,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Track a trip',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
        const SizedBox(height: 4),
        Text('Distance, route on the map, pace and the area you cover.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13, fontWeight: FontWeight.w500)),
        const SizedBox(height: 14),
        Row(children: [
          for (final m in MoveMode.values)
            Expanded(
              child: Tap(
                onTap: () => setState(() => _mode = m),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: EdgeInsets.only(right: m == MoveMode.travel ? 0 : 8),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: _mode == m ? AppColors.lime : Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(children: [
                    Icon(_modeIcon(m), color: _mode == m ? AppColors.ink : Colors.white, size: 22),
                    const SizedBox(height: 4),
                    Text(m.label,
                        style: TextStyle(
                          color: _mode == m ? AppColors.ink : Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        )),
                  ]),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 14),
        AppButton(
          label: 'Start ${_mode.label.toLowerCase()}',
          icon: Icons.play_arrow_rounded,
          busy: _starting,
          onPressed: _start,
          color: AppColors.primary,
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------- steps card

/// Today's steps from the phone sensor, with a ring towards the daily goal. Used on Home and in Move.
class StepsTodayCard extends StatefulWidget {
  const StepsTodayCard({super.key, this.onTap});
  final VoidCallback? onTap;

  @override
  State<StepsTodayCard> createState() => _StepsTodayCardState();
}

class _StepsTodayCardState extends State<StepsTodayCard> with WidgetsBindingObserver {
  final _sc = StepCounter.instance;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sc.start(context.read<Session>().api);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from Settings after allowing the permission.
    if (state == AppLifecycleState.resumed && mounted) _sc.start(context.read<Session>().api);
    if (state == AppLifecycleState.paused) _sc.sync(force: true);
  }

  Future<void> _enable() async {
    setState(() => _asking = true);
    final api = context.read<Session>().api;
    final ok = await _sc.requestAndStart(api);
    if (!mounted) return;
    setState(() => _asking = false);
    if (!ok) {
      final st = await _sc.status();
      if (st.isPermanentlyDenied && mounted) {
        toast(context, 'Allow "Physical activity" for FITKEY in Settings to count steps.');
        await openAppSettings();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _sc,
      builder: (context, _) {
        if (!StepCounter.isSupported) return const SizedBox.shrink();
        final steps = _sc.today;
        final pct = (steps / _stepGoal).clamp(0.0, 1.0);
        final km = steps * 0.00075;
        final kcal = (steps * 0.04).round();
        return AppCard(
          onTap: widget.onTap,
          child: Row(children: [
            SizedBox(
              width: 76,
              height: 76,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: _sc.permitted ? pct : 0,
                    strokeWidth: 8,
                    strokeCap: StrokeCap.round,
                    backgroundColor: AppColors.greenSoft,
                    color: AppColors.green,
                  ),
                ),
                const Icon(Icons.directions_walk_rounded, color: AppColors.green, size: 30),
              ]),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _sc.permitted
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Steps today', style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600)),
                      Text.rich(TextSpan(children: [
                        TextSpan(
                          text: formatNumber(steps),
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6),
                        ),
                        TextSpan(
                          text: ' / ${formatNumber(_stepGoal)}',
                          style: const TextStyle(fontSize: 13, color: AppColors.text3, fontWeight: FontWeight.w700),
                        ),
                      ])),
                      const SizedBox(height: 2),
                      Text(
                        _sc.sensorOk
                            ? '${km.toStringAsFixed(km < 10 ? 2 : 1)} km · $kcal kcal'
                            : 'This phone has no step sensor — add steps in Progress',
                        style: const TextStyle(fontSize: 12.5, color: AppColors.text3, fontWeight: FontWeight.w600),
                      ),
                    ])
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Count your steps automatically',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      const Text('Uses your phone\'s motion sensor. No extra app needed.',
                          style: TextStyle(fontSize: 12.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 38,
                        child: FilledButton(
                          onPressed: _asking ? null : _enable,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.green,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                          ),
                          child: Text(_asking ? 'Asking…' : 'Turn on step counter'),
                        ),
                      ),
                    ]),
            ),
          ]),
        );
      },
    );
  }
}

// ------------------------------------------------------------------------------------------------- track detail

class TrackDetailScreen extends StatelessWidget {
  const TrackDetailScreen({super.key, required this.track});
  final MoveTrack track;

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this trip?'),
        content: const Text('Its route is removed from your map. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await context.read<Session>().api.deleteTrack(track.id);
      if (context.mounted) Navigator.pop(context, true);
    } catch (e) {
      if (context.mounted) toast(context, 'Could not delete: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = track;
    final asSpeed = t.mode == MoveMode.cycle || t.mode == MoveMode.travel;
    final cells = Geo.cellsOf(t.path);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.mode.label),
        actions: [IconButton(onPressed: () => _delete(context), icon: const Icon(Icons.delete_outline_rounded))],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        Text(DateFormat('EEE, d MMM · h:mm a').format(t.startedAt),
            style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(height: 320, child: MoveMap(paths: [t.path], cells: cells)),
        ),
        const SizedBox(height: 14),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.45,
          children: [
            MetricTile(label: 'Distance', value: Geo.km(t.distanceM), icon: Icons.route_rounded, color: _modeColor(t.mode)),
            MetricTile(label: 'Time', value: Geo.duration(t.durationS), icon: Icons.timer_rounded, color: AppColors.blue),
            MetricTile(
              label: asSpeed ? 'Avg speed' : 'Avg pace',
              value: Geo.pace(t.distanceM, t.movingS > 0 ? t.movingS : t.durationS, asSpeed: asSpeed),
              icon: Icons.speed_rounded,
              color: AppColors.amber,
            ),
            MetricTile(label: 'Area explored', value: Geo.area(Geo.areaOf(cells)), icon: Icons.grid_on_rounded, color: AppColors.primary),
            if (!asSpeed && t.steps > 0)
              MetricTile(label: 'Steps', value: formatNumber(t.steps), icon: Icons.directions_walk_rounded, color: AppColors.green),
            if (t.maxSpeedMs != null)
              MetricTile(
                label: 'Top speed',
                value: (t.maxSpeedMs! * 3.6).toStringAsFixed(1),
                unit: 'km/h',
                icon: Icons.bolt_rounded,
                color: AppColors.purple,
              ),
          ],
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------- small parts

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.track, required this.onTap});
  final MoveTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = track;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        IconBubble(_modeIcon(t.mode), color: _modeColor(t.mode)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${t.mode.label} · ${Geo.km(t.distanceM)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 2),
            Text(
              '${DateFormat('d MMM, h:mm a').format(t.startedAt)} · ${Geo.duration(t.durationS)}',
              style: const TextStyle(color: AppColors.text3, fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
      ]),
    );
  }
}

class _BigStat extends StatelessWidget {
  const _BigStat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(value, maxLines: 1, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          Text(label, style: const TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _LiveStat extends StatelessWidget {
  const _LiveStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          FittedBox(
            child: Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
          ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({required this.icon, required this.label, this.live = false});
  final IconData icon;
  final String label;
  final bool live;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(30),
          boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 8)],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (live) ...[
            Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.red, shape: BoxShape.circle)),
            const SizedBox(width: 6),
          ],
          Icon(icon, size: 16, color: AppColors.text),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
        ]),
      );
}
