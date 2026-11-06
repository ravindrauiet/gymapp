// ProveIt plank acceptance (BRD §1.3) on the noisy pose simulation in test/proveit/.
// Simulated, not real-device: the BRD trial with 50–100 users on real phones is still required.
import 'dart:math' as math;

import 'package:fitkey_user/screens/arena/rep_counter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'proveit/pose_sim.dart';
import 'proveit/scenarios.dart';

const _seeds = 12;

Cam _side(math.Random r) => Cam.plankSide(dist: 2.4 + 0.8 * r.nextDouble(), height: 0.2 + 0.3 * r.nextDouble());

/// Runs [build] for several people / camera placements and returns the counters.
List<PlankCounter> _runs(String name, List<Seg> Function(Person p) build,
    {double fps = 12,
    Noise noise = const Noise(),
    Cam Function(math.Random r) cam = _side,
    void Function(SimFrame f, PlankCounter c, List<Seg> segs)? onFrame}) {
  final out = <PlankCounter>[];
  for (var i = 0; i < _seeds; i++) {
    final r = math.Random(4000 + i * 37 + name.length);
    final p = Person(r);
    final segs = build(p);
    final frames = render(segs, cam(r), View.side, r, noise: noise, fps: fps);
    final c = runCounter('plank', frames,
        onFrame: onFrame == null ? null : (f, c) => onFrame(f, c as PlankCounter, segs));
    out.add(c as PlankCounter);
  }
  return out;
}

void main() {
  group('plank timer', () {
    for (final (name, fps, noise) in [
      ('12 fps', 12.0, const Noise()),
      ('15 fps', 15.0, const Noise()),
      ('7 fps with pose dropouts', 7.0, const Noise(poseDropEvery: 8)),
    ]) {
      test('a 60 s hold shows 60 s (±2 s) — $name', () {
        for (final c in _runs('hold $name', (p) => plankHold(p, 60), fps: fps, noise: noise)) {
          expect((c.reps - 60).abs(), lessThanOrEqualTo(2), reason: 'held ${c.heldSeconds}');
          expect(c.holdBroken, isTrue, reason: 'dropping to the floor ends the hold');
        }
      });
    }

    test('a straight-arm plank and a camera 30° off side-on also read 60 s ±2', () {
      for (final c in _runs('high', (p) => plankHold(p, 60, straightArms: true))) {
        expect((c.reps - 60).abs(), lessThanOrEqualTo(2));
      }
      for (final c in _runs('30deg', (p) => plankHold(p, 60), cam: (r) => Cam.plankSide(az: 30))) {
        expect((c.reps - 60).abs(), lessThanOrEqualTo(2));
      }
    });

    for (final (name, sag, knees) in [
      ('sagging hips (13 cm)', 0.13, 0.0),
      ('hips piked up (18 cm)', -0.18, 0.0),
      ('knees on the floor', 0.0, 1.0),
    ]) {
      test('$name pause the timer', () {
        final runs = <PlankCounter>[];
        double? atFaultStart, atFaultEnd;
        var worst = 0.0;
        PlankCounter? current;
        runs.addAll(_runs('fault $name', (p) => plankWithFault(p, 20, 8, 20, sag: sag, knees: knees), onFrame: (f, c, segs) {
          if (!identical(c, current)) {
            current = c;
            atFaultStart = atFaultEnd = null;
          }
          final s = f.t.inMicroseconds / 1e6;
          final faultFrom = startOf(segs, 3) + 0.5 + 0.6; // fault fully in + the pause delay
          final faultTo = startOf(segs, 5);
          if (atFaultStart == null && s >= faultFrom) atFaultStart = c.heldSeconds;
          if (atFaultEnd == null && s >= faultTo) {
            atFaultEnd = c.heldSeconds;
            worst = math.max(worst, atFaultEnd! - atFaultStart!);
          }
        }));
        expect(worst, lessThan(0.5), reason: 'the timer must not run during the fault');
        for (final c in runs) {
          // 40 s of good hold, plus up to ~2 s of the moves into/out of the plank and the fault fading in/out.
          expect(c.heldSeconds, inInclusiveRange(39, 43.5));
          expect(c.partialReps, greaterThanOrEqualTo(1), reason: 'the pause is reported as a form break');
        }
      });
    }

    test('lying on the floor or kneeling upright never runs the timer', () {
      for (final c in _runs('lying', (p) => [Seg(30, (_) => lyingProne(p))])) {
        expect(c.reps, 0);
      }
      for (final c in _runs('kneel', (p) => [Seg(30, (_) => kneelUp(p))])) {
        expect(c.reps, 0);
      }
    });

    test('kneeling out of the plank breaks the hold and ends the set', () {
      for (final c in _runs('kneelout', (p) => plankHold(p, 30, lieDown: false))) {
        expect(c.holdBroken, isTrue);
        expect(UnlimitedSetRule.shouldEnd(c, const Duration(minutes: 1)), isTrue);
        expect((c.reps - 30).abs(), lessThanOrEqualTo(2));
      }
    });
  });
}
