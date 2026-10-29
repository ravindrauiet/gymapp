import 'package:image_picker/image_picker.dart' show XFile;

import 'face_blur_stub.dart' if (dart.library.io) 'face_blur_io.dart' as impl;

/// On-device face blurring for before/after photos (ML Kit face detection + the `image` package).
/// Mobile only — on web [faceBlurSupported] is false and the option is hidden.
bool get faceBlurSupported => impl.faceBlurSupported;

/// Returns a JPEG copy of [file] with every detected face pixelated + blurred, and how many faces were found.
/// Returns the original file when no face was detected.
Future<({XFile file, int faces})> blurFaces(XFile file) => impl.blurFaces(file);
