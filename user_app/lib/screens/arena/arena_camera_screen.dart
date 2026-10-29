// AI rep counting needs the camera + ML Kit, which only exist on Android / iOS. Web gets a friendly stub with the
// same constructor, so this file compiles everywhere.
export 'arena_camera_web.dart' if (dart.library.io) 'arena_camera_mobile.dart';
