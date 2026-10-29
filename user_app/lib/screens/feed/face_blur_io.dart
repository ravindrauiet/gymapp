import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart' show XFile;

bool get faceBlurSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

typedef _Job = ({Uint8List bytes, List<List<int>> rects});

/// Decodes, bakes EXIF orientation, writes an upright copy (so ML Kit and the pixels agree on coordinates).
Uint8List _upright(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('Unsupported image');
  var image = img.bakeOrientation(decoded);
  if (image.width > 1600 || image.height > 1600) {
    image = image.width >= image.height ? img.copyResize(image, width: 1600) : img.copyResize(image, height: 1600);
  }
  return img.encodeJpg(image, quality: 88);
}

/// Pixelates then blurs each face rectangle (padded a little so hairlines / jaw are covered too).
Uint8List _blur(_Job job) {
  final image = img.decodeJpg(job.bytes)!;
  for (final r in job.rects) {
    final padX = (r[2] * 0.18).round(), padY = (r[3] * 0.22).round();
    final x = (r[0] - padX).clamp(0, image.width - 1);
    final y = (r[1] - padY).clamp(0, image.height - 1);
    final w = (r[2] + padX * 2).clamp(1, image.width - x);
    final h = (r[3] + padY * 2).clamp(1, image.height - y);
    var face = img.copyCrop(image, x: x, y: y, width: w, height: h);
    face = img.pixelate(face, size: (w / 10).clamp(8, 60).round());
    face = img.gaussianBlur(face, radius: (w / 14).clamp(6, 40).round());
    img.compositeImage(image, face, dstX: x, dstY: y);
  }
  return img.encodeJpg(image, quality: 88);
}

Future<({XFile file, int faces})> blurFaces(XFile file) async {
  if (!faceBlurSupported) return (file: file, faces: 0);
  final upright = await compute(_upright, await file.readAsBytes());
  final tmp = File('${Directory.systemTemp.path}/fitfeed_${DateTime.now().microsecondsSinceEpoch}.jpg');
  await tmp.writeAsBytes(upright, flush: true);
  final detector = FaceDetector(options: FaceDetectorOptions(performanceMode: FaceDetectorMode.accurate, minFaceSize: 0.05));
  try {
    final faces = await detector.processImage(InputImage.fromFilePath(tmp.path));
    if (faces.isEmpty) return (file: XFile(tmp.path, name: 'photo.jpg', mimeType: 'image/jpeg'), faces: 0);
    final rects = [
      for (final f in faces)
        [f.boundingBox.left.round(), f.boundingBox.top.round(), f.boundingBox.width.round(), f.boundingBox.height.round()],
    ];
    final out = await compute(_blur, (bytes: upright, rects: rects));
    await tmp.writeAsBytes(out, flush: true);
    return (file: XFile(tmp.path, name: 'photo_blurred.jpg', mimeType: 'image/jpeg'), faces: faces.length);
  } finally {
    await detector.close();
  }
}
