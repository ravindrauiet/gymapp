import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/fitkey_api.dart';

/// Today's steps from the phone's own step sensor (Android TYPE_STEP_COUNTER / iOS Core Motion).
///
/// The sensor reports steps since the phone booted, and keeps counting in hardware while FITKEY is closed.
/// We keep a per-day baseline so "today" = current reading − reading at the start of the day (handling
/// reboots), and push the total to the member's report (`/health/steps/sync`, source `phone_sensor`).
class StepCounter extends ChangeNotifier {
  StepCounter._();
  static final instance = StepCounter._();

  static bool get isSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  int _today = 0;
  int get today => _today;

  /// null = not checked yet.
  bool? _permitted;
  bool get permitted => _permitted == true;

  /// False when the phone has no step sensor (or it stopped reporting).
  bool _sensorOk = true;
  bool get sensorOk => _sensorOk;

  bool get running => _sub != null;

  StreamSubscription<StepCount>? _sub;
  FitkeyApi? _api;
  Timer? _syncTimer;
  int _lastSynced = -1;
  DateTime? _lastSyncAt;

  static const _kDay = 'steps.day', _kBase = 'steps.base', _kLast = 'steps.last', _kAcc = 'steps.acc';
  static const _kLastDay = 'steps.lastDay';

  Permission get _permission => defaultTargetPlatform == TargetPlatform.iOS ? Permission.sensors : Permission.activityRecognition;

  Future<PermissionStatus> status() async => isSupported ? _permission.status : PermissionStatus.permanentlyDenied;

  /// Asks for the Physical-activity permission (Android 10+) / Motion & Fitness (iOS), then starts counting.
  Future<bool> requestAndStart(FitkeyApi api) async {
    if (!isSupported) return false;
    final s = await _permission.request();
    _permitted = s.isGranted || s.isLimited;
    notifyListeners();
    if (permitted) await start(api);
    return permitted;
  }

  /// Starts counting if the permission was already granted (never prompts). Safe to call repeatedly.
  Future<void> start(FitkeyApi api) async {
    _api = api;
    if (!isSupported || running) return;
    final s = await _permission.status;
    _permitted = s.isGranted || s.isLimited;
    if (!permitted) {
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    _today = prefs.getString(_kDay) == _dayKey(DateTime.now()) ? _computeToday(prefs, prefs.getInt(_kLast) ?? 0) : 0;
    _sub = Pedometer.stepCountStream.listen(
      (e) => _onReading(prefs, e.steps),
      onError: (Object _) {
        _sensorOk = false;
        _sub?.cancel();
        _sub = null;
        notifyListeners();
      },
      cancelOnError: true,
    );
    _syncTimer ??= Timer.periodic(const Duration(minutes: 3), (_) => sync());
    notifyListeners();
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  int _computeToday(SharedPreferences p, int raw) =>
      (p.getInt(_kAcc) ?? 0) + (raw - (p.getInt(_kBase) ?? raw)).clamp(0, 1 << 30);

  Future<void> _onReading(SharedPreferences p, int raw) async {
    _sensorOk = true;
    final now = DateTime.now();
    final day = _dayKey(now);
    final storedDay = p.getString(_kDay);
    final last = p.getInt(_kLast);

    if (storedDay != day) {
      // New day. Close the previous day first so its final total reaches the report.
      if (storedDay != null && last != null) {
        final prevTotal = _computeToday(p, last);
        await p.setString(_kLastDay, storedDay);
        unawaited(_push(prevTotal, date: storedDay));
      }
      // Steps walked between the last reading and now are counted for today, unless that gap spans more
      // than one night (phone unused for days) — then we start fresh to avoid a giant fake total.
      final yesterday = _dayKey(now.subtract(const Duration(days: 1)));
      final carry = storedDay == yesterday && last != null && raw >= last && raw - last < 30000;
      await p.setString(_kDay, day);
      await p.setInt(_kBase, carry ? last : raw);
      await p.setInt(_kAcc, 0);
    } else if (last != null && raw < last) {
      // The phone rebooted (the sensor restarted from 0): bank what was counted so far today.
      await p.setInt(_kAcc, _computeToday(p, last));
      await p.setInt(_kBase, 0);
    }
    await p.setInt(_kLast, raw);
    _today = _computeToday(p, raw);
    notifyListeners();
    // First reading of a session syncs straight away; after that the periodic timer does.
    if (_lastSynced < 0) unawaited(sync());
  }

  /// Sends today's total to the member's report if it changed (throttled to once a minute unless [force]).
  Future<void> sync({bool force = false}) async {
    if (_api == null || !permitted || _today <= 0 || _today == _lastSynced) return;
    if (!force && _lastSyncAt != null && DateTime.now().difference(_lastSyncAt!) < const Duration(minutes: 1)) return;
    await _push(_today);
  }

  Future<void> _push(int steps, {String? date}) async {
    final api = _api;
    if (api == null || steps <= 0) return;
    try {
      await api.client.post('/health/steps/sync', {
        'steps': steps.clamp(0, 100000),
        'source': 'phone_sensor',
        'date': ?date,
      });
      if (date == null) {
        _lastSynced = steps;
        _lastSyncAt = DateTime.now();
      }
    } catch (_) {
      // Offline or signed out — the next tick retries.
    }
  }
}
