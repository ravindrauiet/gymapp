import 'dart:io';

/// Temporary file for a voice note recording (the app's cache dir on Android / iOS).
Future<String?> voiceNotePath() async =>
    '${Directory.systemTemp.path}/circle_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
