import 'package:image_picker/image_picker.dart' show XFile;

const faceBlurSupported = false;

Future<({XFile file, int faces})> blurFaces(XFile file) async => (file: file, faces: 0);
