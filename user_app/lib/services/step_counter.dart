import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/fitkey_api.dart';

/// One day's total from the phone's step history.
typedef DaySteps = ({String date, int steps});

/// Today's steps, as accurate as the phone allows.
///
/// **Android (primary): Google Play services Recording API** (native channel `fitkey/steps`, see MainActivity.kt).
/// Play services records the hardware step counter in the background all day — also while FITKEY is closed or the
/// phone was never unlocked — so walks taken with the app closed are counted. We read per-day totals for the last
/// 7 days and sync them to the member's report.
///
/// **Live layer:** the Recording API batches data, so between reads we add the steps the live sensor stream
/// (pedometer, TYPE_STEP_COUNTER) has seen since the last read — the number moves while you walk.
///
/// **Fallback (no Play services, iOS):** a per-day baseline over the sensor's since-boot counter (handles reboots).
/// Counts only from FITKEY's first reading of the day.
class StepCounter extends ChangeNotifier with WidgetsBindingObserver {
  StepCounter._();
  static final instance = StepCounter._();

  static bool get isSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static const _channel = MethodChannel('fitkey/steps');

  int _today = 0;
  int get today => _today;

  /// null = not checked yet.
  bool? _permitted;
  bool get permitted => _permitted == true;

  /// False when the phone has no step sensor and no step history.
  bool _sensorOk = true;
  bool get sensorOk => _sensorOk;

  /// True when today's total comes from Play services' background recording (all-day, app closed too).
  bool get usesHistory => _history;
  bool _history = false;

  bool get running => _started;
  bool _started = false;

  StreamSubscription<StepCount>? _sub;
  FitkeyApi? _api;
  Timer? _pollTimer;
  Timer? _syncTimer;
  int _lastSynced = -1;
  DateTime? _lastSyncAt;
  DateTime? _lastHistorySync;

  // History layer
  int _historyToday = 0;
  String? _historyDay;
  int? _rawAtHistoryRead; // sensor reading when the history total was read (for the live layer)
  int? _lastRaw;

  // Fallback (baseline) layer
  int _baselineToday = 0;

  static const _kDay = 'steps.day', _kBase = 'steps.base', _kLast = 'steps.last', _kAcc = 'steps.acc';

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

  /// Starts counting if the permission was already granted (never prompts). Safe to call repeatedly — a repeat
  /// call just refreshes today's total.
  Future<void> start(FitkeyApi api) async {
    _api = api;
    if (!isSupported) return;
    final s = await _permission.status;
    _permitted = s.isGranted || s.isLimited;
    if (!permitted) {
      notifyListeners();
      return;
    }
    if (_started) {
      await refresh();
      return;
    }
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kDay) == _dayKey(DateTime.now())) {
      _baselineToday = _baselineFor(prefs, prefs.getInt(_kLast) ?? 0);
    }

    // History layer (Android + Play services).
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        _history = await _channel.invokeMethod<bool>('subscribe') ?? false;
      } catch (_) {
        _history = false;
      }
    }

    // Live layer + fallback.
    _sub = Pedometer.stepCountStream.listen(
      (e) => _onReading(prefs, e.steps),
      onError: (Object _) {
        // No hardware step counter: history (if any) still works.
        if (!_history) _sensorOk = false;
        notifyListeners();
      },
      cancelOnError: true,
    );

    await refresh();
    _pollTimer ??= Timer.periodic(const Duration(seconds: 60), (_) => refresh());
    _syncTimer ??= Timer.periodic(const Duration(minutes: 3), (_) => sync());
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
    if (state == AppLifecycleState.paused) unawaited(sync(force: true));
  }

  /// Re-reads today's total from the phone's step history (Android) and recomputes.
  Future<void> refresh() async {
    if (_history) {
      try {
        final days = await readHistory(7);
        final todayKey = _dayKey(DateTime.now());
        final t = days.where((d) => d.date == todayKey).firstOrNull;
        if (t != null) {
          _historyToday = t.steps;
          _historyDay = todayKey;
          _rawAtHistoryRead = _lastRaw;
        }
        // Back-fill the last week once an hour so days the app wasn't opened still reach the report.
        if (_lastHistorySync == null || DateTime.now().difference(_lastHistorySync!) > const Duration(hours: 1)) {
          _lastHistorySync = DateTime.now();
          unawaited(_pushDays(days.where((d) => d.date != todayKey && d.steps > 0).toList()));
        }
      } catch (_) {
        // Keep the last value; next poll retries.
      }
    }
    _recompute();
  }

  /// Per-day totals for the last [days] days incl. today, from Play services (empty when unavailable).
  static Future<List<DaySteps>> readHistory(int days) async {
    final raw = await _channel.invokeMethod<List<dynamic>>('readDays', {'days': days}) ?? const [];
    return [
      for (final r in raw)
        (date: (r as Map)['date'] as String, steps: (r['steps'] as num).toInt()),
    ];
  }

  void _recompute() {
    final todayKey = _dayKey(DateTime.now());
    final historyToday = _history && _historyDay == todayKey ? _historyToday : null;
    final next = combineSteps(
      historyToday: historyToday,
      liveSinceRead: _rawAtHistoryRead == null || _lastRaw == null ? 0 : _lastRaw! - _rawAtHistoryRead!,
      baselineToday: _baselineToday,
    );
    if (next != _today) {
      _today = next;
      notifyListeners();
    }
  }

  /// Today's total: history (+ live steps since it was read) when available, never below the baseline count.
  @visibleForTesting
  static int combineSteps({required int? historyToday, required int liveSinceRead, required int baselineToday}) {
    if (historyToday == null) return baselineToday;
    // A reboot resets the sensor (negative delta) — ignore the live layer until the next history read.
    final live = liveSinceRead < 0 || liveSinceRead > 20000 ? 0 : liveSinceRead;
    final h = historyToday + live;
    return h > baselineToday ? h : baselineToday;
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _started = false;
  }

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  int _baselineFor(SharedPreferences p, int raw) =>
      (p.getInt(_kAcc) ?? 0) + (raw - (p.getInt(_kBase) ?? raw)).clamp(0, 1 << 30);

  Future<void> _onReading(SharedPreferences p, int raw) async {
    _sensorOk = true;
    _lastRaw = raw;
    _rawAtHistoryRead ??= raw;
    final now = DateTime.now();
    final day = _dayKey(now);
    final storedDay = p.getString(_kDay);
    final last = p.getInt(_kLast);

    if (storedDay != day) {
      // New day. Without history, close the previous day so its final total reaches the report.
      if (!_history && storedDay != null && last != null) {
        unawaited(_push(_baselineFor(p, last), date: storedDay));
      }
      // Steps between the last reading and now count for today only if the gap is a single night.
      final yesterday = _dayKey(now.subtract(const Duration(days: 1)));
      final carry = storedDay == yesterday && last != null && raw >= last && raw - last < 30000;
      await p.setString(_kDay, day);
      await p.setInt(_kBase, carry ? last : raw);
      await p.setInt(_kAcc, 0);
      // The history total is for yesterday now: re-read.
      if (_history) unawaited(refresh());
    } else if (last != null && raw < last) {
      // The phone rebooted (the sensor restarted from 0): bank what was counted so far today.
      await p.setInt(_kAcc, _baselineFor(p, last));
      await p.setInt(_kBase, 0);
      _rawAtHistoryRead = raw;
    }
    await p.setInt(_kLast, raw);
    _baselineToday = _baselineFor(p, raw);
    _recompute();
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

  Future<void> _pushDays(List<DaySteps> days) async {
    final api = _api;
    if (api == null || days.isEmpty) return;
    try {
      await api.client.post('/health/steps/sync', {
        'source': 'phone_sensor',
        'days': [
          for (final d in days) {'date': d.date, 'steps': d.steps.clamp(0, 100000)},
        ],
      });
    } catch (_) {}
  }
}
