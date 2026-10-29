import '../../data/fitkey_api.dart';

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

/// Automatic step sync (Health Connect / HealthKit) is switched OFF until the Play Console
/// health declaration is approved; Progress uses manual step entry everywhere meanwhile.
/// The full implementation is kept in `health_sync.dart.health_connect.disabled` — to re-enable:
/// restore it over this file, `flutter pub add health`, and re-add the Health Connect permissions,
/// rationale intent-filter, activity-alias and queries entries to AndroidManifest.xml.
class HealthSync {
  HealthSync._();
  static final instance = HealthSync._();

  bool get isSupported => false;

  String get source => 'manual';
  String get providerName => 'Health Connect';

  Future<HealthSyncState> state() async => HealthSyncState.unsupported;

  Future<bool> connect() async => false;

  Future<void> installHealthConnect() async {}

  Future<int> syncRecent(FitkeyApi api, {int days = 7}) async => 0;
}
