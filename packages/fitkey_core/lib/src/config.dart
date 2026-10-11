import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Backend base URL. Override at build time:
///   flutter run --dart-define=API_URL=https://api.fitkey.in/api/v1
class AppConfig {
  static const _fromEnv = String.fromEnvironment('API_URL');

  static String get apiUrl {
    if (_fromEnv.isNotEmpty) return _fromEnv;
    // Android emulator reaches the host machine via 10.0.2.2; iOS simulator via localhost.
    if (!kIsWeb && Platform.isAndroid) return 'http://10.0.2.2:4000/api/v1';
    return 'http://localhost:4000/api/v1';
  }
}

/// Photos uploaded through the API are stored as server-relative paths (`/api/v1/files/<id>`)
/// so they work whichever host a device uses to reach the backend. Absolute URLs pass through.
String? resolveMediaUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  if (!url.startsWith('/')) return url;
  final api = Uri.parse(AppConfig.apiUrl);
  return api.replace(path: url, query: null).toString();
}
