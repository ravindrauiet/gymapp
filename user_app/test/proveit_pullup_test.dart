// ProveIt pullup acceptance (BRD §1.3) on the noisy pose simulation in test/proveit/.
// Simulated, not real-device: the BRD trial with 50–100 users on real phones is still required.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'proveit/pose_sim.dart';
import 'proveit/scenarios.dart';

const _seeds = 20;

Cam _front(math.Random r) =>
    Cam.front(dist: 2.3 + 0.8 * r.nextDouble(), height: 0.8 + 0.5 * r.nextDouble(), az: (r.nextDouble() - 0.5) * 40);

List<int> _reps(String name, List<Seg> Function(Person p, math.Random r) build,
    {double fps = 12, Noise noise = const Noise()}) {
  final out = <int>[];
  for (var i = 0; i < _seeds; i++) {
    final r = math.Random(7000 + i * 41 + name.length);
    final p = Person(r);
    final segs = build(p, r);
    out.add(runCounter('pullups', render(segs, _front(r), View.front, r, noise: noise, fps: fps)).reps);
  }
  return out;
}

void main() {
  group('pullups', () {
    test('10 real pullups = 10 (noise-free control)', () {
      expect(
          _reps('clean', (p, r) => [...jumpToHang(p), ...pullupReps(p, r, 10), ...dropOff(p)],
              noise: const Noise(clean: true)),
          everyElement(10));
    });

    for (final (name, fps, legs) in [('12 fps, bent knees', 12.0, 0.4), ('15 fps, straight legs', 15.0, 0.0)]) {
      test('10 real pullups = 10 under landmark noise — $name', () {
        final reps = _reps(
            name,
            (p, r) => [
                  ...jumpToHang(p, kneeBend: legs),
                  ...pullupReps(p, r, 10, kneeBend: legs),
                  ...dropOff(p, kneeBend: legs),
                ],
            fps: fps);
        // Never more than were done; a tracking glitch may occasionally cost one rep.
        expect(reps, everyElement(inInclusiveRange(9, 10)));
        expect(reps.where((n) => n == 10).length, greaterThanOrEqualTo(_seeds * 0.9));
      });
    }

    test('standing and copying the arm movement = 0 reps', () {
      expect(_reps('wave', (p, r) => armWaving(p, 10)), everyElement(0));
      expect(_reps('wave+calf raise', (p, r) => armWaving(p, 10, lift: 0.07)), everyElement(0));
      expect(_reps('wave+squat', (p, r) => armWaving(p, 10, squat: 0.9)), everyElement(0));
    });

    test('squatting under a low bar (the legs do the work) = 0 reps', () {
      expect(_reps('low bar', (p, r) => armWaving(p, 10, squat: 1.0, fixedHands: 1.6)), everyElement(0));
    });

    test('half reps (chin never over the bar) = 0 reps', () {
      expect(_reps('half', (p, r) => [...jumpToHang(p), ...pullupReps(p, r, 10, top: 0.6), ...dropOff(p)]),
          everyElement(0));
    });

    test('never straightening the arms between reps counts at most the last one', () {
      expect(_reps('no lockout', (p, r) => [...jumpToHang(p), ...pullupReps(p, r, 10, bottom: 0.45), ...dropOff(p)]),
          everyElement(lessThanOrEqualTo(1)));
    });

    test('hanging still = 0 reps', () {
      expect(_reps('still', (p, r) => [...jumpToHang(p), Seg(20, (_) => hang(p, 0)), ...dropOff(p)]), everyElement(0));
    });
  });
}
