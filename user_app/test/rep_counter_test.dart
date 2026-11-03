import 'package:fitkey_user/screens/arena/rep_counter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Side-on pushup frame. [shoulderDrop] lowers the shoulders in pixels from the top position (torso is 200 px long).
/// When [feetVisible] is false the ankles are missing, like a phone that can't see the feet.
PoseFrame _side({double shoulderDrop = 0, bool bentElbow = false, bool feetVisible = true}) {
  final y = 240 + shoulderDrop;
  return <Joint, Pt>{
    Joint.leftShoulder: Pt(100, y, 0.95),
    Joint.leftHip: Pt(300, y + 3, 0.95),
    Joint.leftKnee: Pt(420, y + 6, 0.95),
    if (feetVisible) Joint.leftAnkle: Pt(520, y + 9, 0.95),
    Joint.leftElbow: bentElbow ? Pt(40, y, 0.95) : Pt(100, y + 60, 0.95),
    Joint.leftWrist: bentElbow ? Pt(40, 360, 0.95) : Pt(100, 360, 0.95),
  };
}

/// Head-on pushup frame: the torso is foreshortened, both shoulders are visible, and the elbow angle says little.
PoseFrame _front({double shoulderDrop = 0}) {
  final y = 200 + shoulderDrop;
  return <Joint, Pt>{
    Joint.nose: Pt(200, y - 20, 0.95),
    Joint.leftShoulder: Pt(150, y, 0.95),
    Joint.rightShoulder: Pt(250, y, 0.95),
    Joint.leftHip: Pt(165, y + 20, 0.95),
    Joint.rightHip: Pt(235, y + 20, 0.95),
    Joint.leftElbow: Pt(130, y + 50, 0.95),
    Joint.rightElbow: Pt(270, y + 50, 0.95),
    Joint.leftWrist: Pt(145, 310, 0.95),
    Joint.rightWrist: Pt(255, 310, 0.95),
  };
}

int _run(String id, PoseFrame Function(bool down) frame, {int reps = 3, Duration hold = const Duration(milliseconds: 800)}) {
  final c = RepCounter.forExercise(id);
  var t = Duration.zero;
  void feed(bool down) {
    for (var i = 0; i < hold.inMilliseconds ~/ 100; i++) {
      t += const Duration(milliseconds: 100);
      c.update(frame(down), t);
    }
  }

  feed(false);
  feed(false);
  for (var i = 0; i < reps; i++) {
    feed(true);
    feed(false);
  }
  return c.reps;
}

void main() {
  group('pushups', () {
    PoseFrame sideRep(bool down) => down ? _side(shoulderDrop: 70, bentElbow: true) : _side();

    test('counts side-on reps with the whole body in frame', () {
      expect(_run('pushups', sideRep), 3);
    });

    test('counts reps when the feet are out of frame', () {
      expect(
        _run('pushups', (down) => down ? _side(shoulderDrop: 70, bentElbow: true, feetVisible: false) : _side(feetVisible: false)),
        3,
      );
    });

    test('counts reps when the elbow never looks bent in 2D (flared elbows)', () {
      expect(_run('pushups', (down) => down ? _side(shoulderDrop: 70) : _side()), 3);
    });

    test('counts head-on reps, which the old elbow counter could never start', () {
      expect(_run('pushups', (down) => down ? _front(shoulderDrop: 45) : _front()), 3);
    });

    test('does not count partial reps', () {
      expect(_run('pushups', (down) => down ? _side(shoulderDrop: 22) : _side()), 0);
    });

    test('does not count a plank held still', () {
      expect(_run('pushups', (_) => _side()), 0);
    });

    test('does not count someone standing up', () {
      final standing = <Joint, Pt>{
        Joint.leftShoulder: Pt(200, 120, 0.95),
        Joint.leftElbow: Pt(200, 190, 0.95),
        Joint.leftWrist: Pt(200, 260, 0.95),
        Joint.leftHip: Pt(200, 300, 0.95),
        Joint.leftKnee: Pt(200, 420, 0.95),
        Joint.leftAnkle: Pt(200, 530, 0.95),
      };
      expect(_run('pushups', (_) => standing), 0);
    });
  });
}
