// ProveIt simulation timelines shared by the plank and pullup tests.
import 'dart:math' as math;

import 'pose_sim.dart';

// --------------------------------------------------------------------------------------------- plank
/// Natural hold: breathing, a little sway of the hips (±2 cm) and a slow fatigue sag of up to [fatigue] metres.
Pose3 holdFrame(Person p, double s, double dur, {double baseSag = 0.015, double fatigue = 0.035, bool straightArms = false, double phase = 0}) {
  final sec = s * dur;
  final breathe = math.sin(2 * math.pi * (sec / 4.0 + phase));
  final wobble = 0.012 * math.sin(2 * math.pi * (sec / 7.3 + phase)) + 0.006 * math.sin(2 * math.pi * sec / 2.1);
  return plank(p, sag: baseSag + fatigue * s + wobble, breathe: breathe, straightArms: straightArms);
}

/// Kneeling on hands/forearms (knees down) → lift into the plank over [t] seconds.
Seg getIntoPlank(Person p, {double t = 1.6, bool straightArms = false}) {
  final kneeling = plank(p, knees: 1, straightArms: straightArms);
  final up = plank(p, sag: 0.015, straightArms: straightArms);
  return Seg(t, (s) => lerpPose(kneeling, up, ramp(s)));
}

/// Plank → lying flat on the floor, then lies there.
List<Seg> dropToFloor(Person p, {double rest = 4}) {
  final from = plank(p, sag: 0.04), to = lyingProne(p);
  return [Seg(0.9, (s) => lerpPose(from, to, ramp(s))), Seg(rest, (_) => to)];
}

/// Plank → knees down → kneeling upright.
List<Seg> kneelOut(Person p, {double rest = 4}) {
  final from = plank(p, sag: 0.04), knees = plank(p, knees: 1), up = kneelUp(p);
  return [
    Seg(0.6, (s) => lerpPose(from, knees, ramp(s))),
    Seg(1.0, (s) => lerpPose(knees, up, ramp(s))),
    Seg(rest, (_) => up),
  ];
}

/// Kneels in front of the phone for [t] s (setting up after the countdown).
Seg setUp(Person p, {double t = 3}) {
  final up = kneelUp(p), kn = plank(p, knees: 1);
  return Seg(t, (s) => lerpPose(up, kn, ramp(s * 1.4)));
}

/// [hold] seconds of good plank (after getting into it), then the hold breaks.
List<Seg> plankHold(Person p, double hold, {bool straightArms = false, bool lieDown = true}) => [
      setUp(p),
      getIntoPlank(p, straightArms: straightArms),
      Seg(hold, (s) => holdFrame(p, s, hold, straightArms: straightArms)),
      ...(lieDown ? dropToFloor(p) : kneelOut(p)),
    ];

/// Good hold [a] s, then [bad] seconds with the given fault, then good hold [b] s, then drop.
/// The fault fades in and out over 0.5 s (part of [bad]).
List<Seg> plankWithFault(Person p, double a, double bad, double b, {double sag = 0, double knees = 0}) {
  final good = plank(p, sag: 0.02);
  final faulty = plank(p, sag: sag, knees: knees);
  return [
    setUp(p),
    getIntoPlank(p),
    Seg(a, (s) => holdFrame(p, s, a, fatigue: 0.005)),
    Seg(0.5, (s) => lerpPose(good, faulty, ramp(s))),
    Seg(bad - 1.0, (s) => plank(p, sag: sag + 0.01 * math.sin(2 * math.pi * s * 3), knees: knees)),
    Seg(0.5, (s) => lerpPose(faulty, good, ramp(s))),
    Seg(b, (s) => holdFrame(p, s, b, fatigue: 0.01, phase: 0.3)),
    ...dropToFloor(p),
  ];
}

// --------------------------------------------------------------------------------------------- pullups
/// Walk up, reach and jump into a dead hang.
List<Seg> jumpToHang(Person p, {double kneeBend = 0.4}) {
  final st = stand(p, armsDown: 1), reach = stand(p, arms: 0), h = hang(p, 0, kneeBend: kneeBend);
  return [
    Seg(2.0, (_) => st),
    Seg(0.8, (s) => lerpPose(st, reach, ramp(s))),
    Seg(0.6, (s) => lerpPose(reach, h, ramp(s))),
    Seg(1.2, (s) => hang(p, 0, kneeBend: kneeBend, sway: 0.02 * math.sin(2 * math.pi * s))),
  ];
}

/// Drop off the bar and stand.
List<Seg> dropOff(Person p, {double kneeBend = 0.4}) {
  final h = hang(p, 0, kneeBend: kneeBend), st = stand(p, armsDown: 1);
  return [Seg(0.7, (s) => lerpPose(h, st, ramp(s))), Seg(2.5, (_) => st)];
}

/// [n] pullups. [top] how far up each rep goes (1 = chin over the bar), [bottom] how far down (0 = dead hang).
List<Seg> pullupReps(Person p, math.Random r, int n,
    {double top = 1, double bottom = 0, double dur = 2.4, double kneeBend = 0.4, double noseOver = 0.12, double swing = 0.03}) {
  final out = <Seg>[];
  for (var i = 0; i < n; i++) {
    final d = dur * (0.8 + 0.45 * r.nextDouble());
    final over = noseOver + 0.04 * (r.nextDouble() - 0.5);
    final pause = 0.2 + 0.6 * r.nextDouble();
    final sw = swing * (r.nextDouble() - 0.5) * 2;
    out.add(Seg(d, (s) {
      final q = bottom + (top - bottom) * bump(s);
      return hang(p, q, kneeBend: kneeBend, noseOver: over, sway: sw * math.sin(2 * math.pi * s));
    }));
    out.add(Seg(pause, (_) => hang(p, bottom, kneeBend: kneeBend)));
  }
  return out;
}

/// Standing in front of the phone copying the pullup with the arms: [n] times straight-overhead → pulled down.
/// [lift] adds a calf raise on every "pull"; [squat] squats at the "hang" and stands on the "pull".
List<Seg> armWaving(Person p, int n, {double lift = 0, double squat = 0, double dur = 2.2, double? fixedHands}) {
  return [
    Seg(2, (_) => stand(p, armsDown: 1)),
    Seg(0.8, (s) => lerpPose(stand(p, armsDown: 1), stand(p, squat: squat), ramp(s))),
    Seg(1.0, (_) => stand(p, squat: squat, fixedHands: fixedHands)),
    for (var i = 0; i < n; i++)
      Seg(dur, (s) {
        final q = bump(s);
        return stand(p, arms: q, lift: lift * q, squat: squat * (1 - q), fixedHands: fixedHands);
      }),
    Seg(2, (_) => stand(p, squat: squat, fixedHands: fixedHands)),
  ];
}
