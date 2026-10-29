import 'package:flutter/material.dart';

import 'rep_counter.dart';

const _bones = [
  (Joint.leftShoulder, Joint.rightShoulder),
  (Joint.leftShoulder, Joint.leftElbow),
  (Joint.leftElbow, Joint.leftWrist),
  (Joint.rightShoulder, Joint.rightElbow),
  (Joint.rightElbow, Joint.rightWrist),
  (Joint.leftShoulder, Joint.leftHip),
  (Joint.rightShoulder, Joint.rightHip),
  (Joint.leftHip, Joint.rightHip),
  (Joint.leftHip, Joint.leftKnee),
  (Joint.leftKnee, Joint.leftAnkle),
  (Joint.rightHip, Joint.rightKnee),
  (Joint.rightKnee, Joint.rightAnkle),
];

/// Draws the detected skeleton over the camera preview.
///
/// [imageSize] is the size of the upright image ML Kit analysed; points are scaled to the canvas (the preview
/// box has the same aspect ratio) and mirrored for the front camera, whose preview is mirrored.
class PosePainter extends CustomPainter {
  PosePainter({required this.pose, required this.imageSize, required this.mirror, required this.color});

  final PoseFrame? pose;
  final Size imageSize;
  final bool mirror;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = pose;
    if (p == null || imageSize.isEmpty) return;
    Offset map(Pt pt) {
      final x = pt.x * size.width / imageSize.width;
      return Offset(mirror ? size.width - x : x, pt.y * size.height / imageSize.height);
    }

    bool ok(Joint j) => (p[j]?.likelihood ?? 0) >= kMinLikelihood;

    final bone = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    for (final (a, b) in _bones) {
      if (ok(a) && ok(b)) canvas.drawLine(map(p[a]!), map(p[b]!), bone);
    }
    final dotFill = Paint()..color = Colors.white;
    final dotRing = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (final j in Joint.values) {
      if (!ok(j)) continue;
      final o = map(p[j]!);
      canvas.drawCircle(o, 6, dotFill);
      canvas.drawCircle(o, 6, dotRing);
    }
  }

  @override
  bool shouldRepaint(PosePainter old) =>
      old.pose != pose || old.imageSize != imageSize || old.mirror != mirror || old.color != color;
}
