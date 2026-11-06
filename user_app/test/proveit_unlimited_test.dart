import 'package:fitkey_user/screens/arena/rep_counter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Side-on pushup frame (same geometry as rep_counter_test.dart).
PoseFrame _side({double drop = 0, bool bent = false}) {
  final y = 240 + drop;
  return <Joint, Pt>{
    Joint.leftShoulder: Pt(100, y, 0.95),
    Joint.leftHip: Pt(300, y + 3, 0.95),
    Joint.leftKnee: Pt(420, y + 6, 0.95),
    Joint.leftAnkle: Pt(520, y + 9, 0.95),
    Joint.leftElbow: bent ? Pt(40, y, 0.95) : Pt(100, y + 60, 0.95),
    Joint.leftWrist: bent ? Pt(40, 360, 0.95) : Pt(100, 360, 0.95),
  };
}

void main() {
  test('Unlimited ends 5 s after the last rep, not before', () {
    final c = RepCounter.forExercise('pushups');
    var t = Duration.zero;
    void feed(PoseFrame f, int ms) {
      for (var i = 0; i < ms ~/ 100; i++) {
        t += const Duration(milliseconds: 100);
        c.update(f, t);
      }
    }

    feed(_side(), 1600);
    for (var i = 0; i < 3; i++) {
      feed(_side(drop: 70, bent: true), 800);
      feed(_side(), 800);
    }
    expect(c.reps, 3);
    final last = c.lastRepAt!;
    expect(UnlimitedSetRule.shouldEnd(c, last + const Duration(milliseconds: 4900)), isFalse);
    expect(UnlimitedSetRule.shouldEnd(c, last + const Duration(seconds: 5)), isTrue);
  });

  test('Unlimited gives 20 s to start, and a camera switch keeps the score', () {
    final c = RepCounter.forExercise('squats');
    expect(UnlimitedSetRule.shouldEnd(c, const Duration(seconds: 19)), isFalse);
    expect(UnlimitedSetRule.shouldEnd(c, const Duration(seconds: 20)), isTrue);
    c.reps = 7;
    c.partialReps = 2;
    final n = c.carryOver('squats');
    expect(n.reps, 7);
    expect(n.partialReps, 2);
    final p = PlankCounter()..heldSeconds = 42.5;
    expect((p.carryOver('plank') as PlankCounter).heldSeconds, 42.5);
  });
}
