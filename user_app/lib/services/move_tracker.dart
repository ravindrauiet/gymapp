import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/activity_api.dart';
import '../data/fitkey_api.dart';
import 'geo.dart';
import 'step_counter.dart';

/// Records one walk / run / ride / travel: GPS route, distance, moving time, steps and the area explored.
///
/// On Android it runs as a foreground service with an ongoing notification, so recording continues with the
/// screen off or the app in the background (only "while using the app" location permission is needed because
/// the member starts it from the app). iOS uses background location updates for the same purpose.
class MoveTracker extends ChangeNotifier {
  MoveTracker._();
  static final instance = MoveTracker._();

  bool get recording => _sub != null;
  MoveMode mode = MoveMode.walk;
  DateTime? startedAt;
  final List<LatLng> points = [];
  double distanceM = 0;
  int movingS = 0;
  double maxSpeedMs = 0;
  double? accuracyM;
  int _startSteps = 0;
  final Set<(int, int)> cells = {};

  StreamSubscription<Position>? _sub;
  Timer? _ticker;
  Position? _last;

  int get elapsedS => startedAt == null ? 0 : DateTime.now().difference(startedAt!).inSeconds;
  int get steps => (StepCounter.instance.today - _startSteps).clamp(0, 200000);
  double get areaM2 => Geo.areaOf(cells);
  LatLng? get current => points.isEmpty ? null : points.last;

  /// Checks GPS + permission. Returns an error message for the member, or null when ready.
  static Future<String?> ensureLocation({bool request = true}) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Turn on location (GPS) to record your route.';
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied && request) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied) return 'Location permission is needed to record your route.';
    if (p == LocationPermission.deniedForever) {
      return 'Location is blocked for FITKEY. Allow it in Settings → Apps → FITKEY → Permissions.';
    }
    return null;
  }

  LocationSettings _settings() {
    if (kIsWeb) return const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 5);
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: 3),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'FITKEY is recording your ${mode.label.toLowerCase()}',
          notificationText: 'Distance and route are being tracked. Open FITKEY to stop.',
          notificationChannelName: 'Move tracking',
          enableWakeLock: true,
          setOngoing: true,
          color: const Color(0xFFFF5A36),
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.best,
        activityType: mode == MoveMode.travel ? ActivityType.automotiveNavigation : ActivityType.fitness,
        distanceFilter: 5,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 5);
  }

  Future<String?> start(MoveMode m) async {
    if (recording) return null;
    final err = await ensureLocation();
    if (err != null) return err;
    mode = m;
    startedAt = DateTime.now();
    points.clear();
    cells.clear();
    distanceM = 0;
    movingS = 0;
    maxSpeedMs = 0;
    _last = null;
    _startSteps = StepCounter.instance.today;
    try {
      _sub = Geolocator.getPositionStream(locationSettings: _settings()).listen(_onPosition, onError: (Object _) {});
    } catch (e) {
      return 'Could not start GPS: $e';
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    notifyListeners();
    return null;
  }

  void _onPosition(Position p) {
    accuracyM = p.accuracy;
    // Ignore poor fixes (indoors, first seconds after GPS start).
    if (p.accuracy > 35) {
      notifyListeners();
      return;
    }
    final here = LatLng(p.latitude, p.longitude);
    final prev = _last;
    if (prev == null) {
      _accept(p, here);
      return;
    }
    final d = Geo.distance(LatLng(prev.latitude, prev.longitude), here);
    final dt = p.timestamp.difference(prev.timestamp).inMilliseconds / 1000.0;
    if (dt <= 0) return;
    final speed = d / dt;
    // Jitter while standing still: movement smaller than the fix's own uncertainty.
    if (d < (p.accuracy * 0.6).clamp(4.0, 20.0)) return;
    // Teleport: GPS jumped faster than this mode allows.
    if (speed > mode.maxSpeed) return;
    distanceM += d;
    if (speed > 0.4) movingS += dt.round();
    if (speed > maxSpeedMs && d > 15) maxSpeedMs = speed;
    _accept(p, here);
  }

  void _accept(Position p, LatLng here) {
    _last = p;
    if (points.isNotEmpty) {
      cells.addAll(Geo.cellsOf([points.last, here]));
    } else {
      cells.add(Geo.cellOf(here));
    }
    points.add(here);
    notifyListeners();
  }

  Future<void> _stopStream() async {
    await _sub?.cancel();
    _sub = null;
    _ticker?.cancel();
    _ticker = null;
  }

  /// Drops the current recording.
  Future<void> discard() async {
    await _stopStream();
    startedAt = null;
    points.clear();
    cells.clear();
    notifyListeners();
  }

  /// Stops and saves. Returns the saved track, or null if it was too short to keep.
  /// If the upload fails the track is kept on the phone and retried by [flushPending].
  Future<MoveTrack?> stopAndSave(FitkeyApi api) async {
    final started = startedAt;
    await _stopStream();
    if (started == null) return null;
    final ended = DateTime.now();
    final body = <String, dynamic>{
      'startedAt': started.toUtc().toIso8601String(),
      'endedAt': ended.toUtc().toIso8601String(),
      'mode': mode.api,
      'distanceM': distanceM,
      'durationS': ended.difference(started).inSeconds,
      'movingS': movingS,
      'steps': mode == MoveMode.travel || mode == MoveMode.cycle ? 0 : steps,
      'areaM2': areaM2,
      if (maxSpeedMs > 0) 'maxSpeedMs': maxSpeedMs,
      'path': [
        for (final p in Geo.simplify(points)) [_round(p.latitude), _round(p.longitude)],
      ].take(5000).toList(),
    };
    final m = mode;
    startedAt = null;
    points.clear();
    cells.clear();
    notifyListeners();
    if ((body['distanceM'] as double) < 30) return null;
    try {
      final saved = await api.saveTrack(body);
      await _logToProgress(api, m, body);
      return saved;
    } catch (_) {
      await _queue(body);
      rethrow;
    }
  }

  static double _round(double v) => (v * 1e6).roundToDouble() / 1e6;

  /// Walks, runs and rides also count as activities in the Progress report (calories etc.).
  Future<void> _logToProgress(FitkeyApi api, MoveMode m, Map<String, dynamic> body) async {
    final type = m.activityType;
    if (type == null) return;
    try {
      await api.logActivity({
        'type': type,
        'title': m == MoveMode.walk ? 'Walk' : m.label,
        'durationMin': ((body['durationS'] as int) / 60).round().clamp(1, 1440),
        'distanceKm': double.parse(((body['distanceM'] as double) / 1000).toStringAsFixed(2)),
        'loggedAt': body['startedAt'],
      });
    } catch (_) {}
  }

  static const _kPending = 'move.pending';

  Future<void> _queue(Map<String, dynamic> body) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_kPending) ?? [];
    await p.setStringList(_kPending, [...list, jsonEncode(body)]);
  }

  /// Uploads tracks that couldn't be saved earlier (no network at the time).
  Future<int> flushPending(FitkeyApi api) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_kPending) ?? [];
    if (list.isEmpty) return 0;
    final left = <String>[];
    var sent = 0;
    for (final s in list) {
      try {
        final body = jsonDecode(s) as Map<String, dynamic>;
        await api.saveTrack(body);
        await _logToProgress(api, MoveMode.parse(body['mode'] as String?), body);
        sent++;
      } catch (_) {
        left.add(s);
      }
    }
    await p.setStringList(_kPending, left);
    return sent;
  }
}
