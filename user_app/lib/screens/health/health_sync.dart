import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/fitkey_api.dart';
import '../../data/progress_api.dart';

enum HealthSyncState {
  /// Web / desktop — enter steps manually.
  unsupported,

  /// Android without the Health Connect app (or it needs an update).
  notInstalled,

  /// Available, but the member hasn't granted access yet.
  needsPermission,

  /// Access granted — steps sync automatically.
  connected,
}

/// Reads steps, distance and active calories from Health Connect (Android) / HealthKit (iOS)
/// and back-fills them into the member's FITKEY report via POST /health/steps/sync.
class HealthSync {
  HealthSync._();
  static final instance = HealthSync._();

  final Health _health = Health();
  bool _configured = false;

  static const playStoreUrl = 'https://play.google.com/store/apps/details?id=com.google.android.apps.healthdata';

  bool get isSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  bool get _isIos => defaultTargetPlatform == TargetPlatform.iOS;

  String get source => _isIos ? 'apple_healthkit' : 'health_connect';
  String get providerName => _isIos ? 'Apple Health' : 'Health Connect';

  List<HealthDataType> get _types => [
        HealthDataType.STEPS,
        _isIos ? HealthDataType.DISTANCE_WALKING_RUNNING : HealthDataType.DISTANCE_DELTA,
        HealthDataType.ACTIVE_ENERGY_BURNED,
      ];

  Future<void> _configure() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  Future<HealthSyncState> state() async {
    if (!isSupported) return HealthSyncState.unsupported;
    try {
      await _configure();
      if (!_isIos) {
        final status = await _health.getHealthConnectSdkStatus();
        if (status != HealthConnectSdkStatus.sdkAvailable) return HealthSyncState.notInstalled;
      }
      final has = await _health.hasPermissions(_types);
      // HealthKit never reveals read access (null) — treat as connected once the member has synced before.
      if (has == true) return HealthSyncState.connected;
      return HealthSyncState.needsPermission;
    } catch (_) {
      return _isIos ? HealthSyncState.needsPermission : HealthSyncState.notInstalled;
    }
  }

  /// One-time permission prompt. Returns true when access was granted.
  Future<bool> connect() async {
    if (!isSupported) return false;
    await _configure();
    return _health.requestAuthorization(_types);
  }

  /// Opens the Play Store listing for Health Connect.
  Future<void> installHealthConnect() async {
    try {
      await _configure();
      await _health.installHealthConnect();
    } catch (_) {
      await launchUrl(Uri.parse(playStoreUrl), mode: LaunchMode.externalApplication);
    }
  }

  /// Reads the last [days] days (today included) and syncs every day that has steps.
  /// Returns the number of days saved.
  Future<int> syncRecent(FitkeyApi api, {int days = 7}) async {
    if (!isSupported) return 0;
    await _configure();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(Duration(days: days - 1));

    // Distance & active calories: sum data points per local day.
    final distance = <DateTime, double>{};
    final calories = <DateTime, double>{};
    try {
      final points = await _health.getHealthDataFromTypes(types: _types.sublist(1), startTime: start, endTime: now);
      for (final p in points) {
        final v = p.value;
        if (v is! NumericHealthValue) continue;
        final day = DateTime(p.dateFrom.year, p.dateFrom.month, p.dateFrom.day);
        if (p.type == HealthDataType.ACTIVE_ENERGY_BURNED) {
          calories[day] = (calories[day] ?? 0) + v.numericValue.toDouble();
        } else {
          distance[day] = (distance[day] ?? 0) + v.numericValue.toDouble(); // metres
        }
      }
    } catch (_) {
      // Distance / calories are optional — steps alone are enough.
    }

    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < days; i++) {
      final day = start.add(Duration(days: i));
      final end = i == days - 1 ? now : day.add(const Duration(days: 1));
      final steps = await _health.getTotalStepsInInterval(day, end) ?? 0;
      if (steps <= 0) continue;
      final km = (distance[day] ?? 0) / 1000;
      final kcal = (calories[day] ?? 0).round();
      rows.add({
        'date': _apiDate(day),
        'steps': steps.clamp(0, 100000),
        if (km > 0) 'distanceKm': double.parse(km.clamp(0, 200).toStringAsFixed(2)),
        if (kcal > 0) 'activeCalories': kcal.clamp(0, 10000),
      });
    }
    if (rows.isEmpty) return 0;
    return api.syncStepDays(rows, source: source);
  }

  static String _apiDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
