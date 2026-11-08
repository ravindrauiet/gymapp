import 'package:permission_handler/permission_handler.dart';

import '../../data/fitkey_api.dart';
import '../../services/step_counter.dart';

enum HealthSyncState {
  /// Automatic sync isn't available — members enter steps manually.
  unsupported,

  /// Android without the Health Connect app (or it needs an update).
  notInstalled,

  /// Available, but the member hasn't granted access yet.
  needsPermission,

  /// Access granted — steps sync automatically.
  connected,
}

/// Automatic steps come from the phone's own step sensor ([StepCounter]) — no Health Connect, so no Play health
/// declaration is needed. The old Health Connect / HealthKit implementation is kept in
/// `health_sync.dart.health_connect.disabled`.
class HealthSync {
  HealthSync._();
  static final instance = HealthSync._();

  bool get isSupported => StepCounter.isSupported;

  String get source => 'phone_sensor';
  String get providerName => 'your phone\'s step counter';

  Future<HealthSyncState> state() async {
    if (!isSupported) return HealthSyncState.unsupported;
    final s = await StepCounter.instance.status();
    return s.isGranted || s.isLimited ? HealthSyncState.connected : HealthSyncState.needsPermission;
  }

  Future<bool> connect(FitkeyApi api) => StepCounter.instance.requestAndStart(api);

  Future<void> installHealthConnect() async {}

  /// Pushes today's sensor total to the report. Returns the number of days synced (0 or 1).
  Future<int> syncRecent(FitkeyApi api, {int days = 7}) async {
    final sc = StepCounter.instance;
    await sc.start(api);
    if (!sc.permitted) return 0;
    // Give the sensor a moment to deliver its first reading after start.
    for (var i = 0; i < 10 && sc.today == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (sc.today <= 0) return 0;
    await sc.sync(force: true);
    return 1;
  }
}
