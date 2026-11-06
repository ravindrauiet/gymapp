// ProveIt rep counting ("Only real reps count"): pure Dart state machines over pose landmarks (no Flutter / ML Kit
// imports, so the logic can be simulated and unit-tested off-device — see test/proveit/pose_sim.dart).
//
// Coordinates are image pixels in the upright frame ML Kit returns (y grows downwards). Angles are invariant to
// scale, rotation and mirroring, so they don't depend on how the phone is held; "above"/"below" checks rely on the
// frame being upright, which the camera screen guarantees by passing the correct rotation to ML Kit.
//
// Threshold choices (degrees). Reference ranges from strength-coaching standards for a full-range rep, widened a
// little because (a) ML Kit landmarks jitter by roughly ±5–10° on a phone camera and (b) the moving-average filter
// below shaves a few degrees off the true extremes:
//   pushup  elbow  ≤ 95 = bottom (≈ 90° = chest near the floor),  ≥ 158 = locked out (fully straight ≈ 170–180)
//           body (shoulder–hip–ankle) must stay ≥ 145 through the rep (straight ≈ 180; sag/pike drops it)
//   squat   knee   ≤ 100 = depth (thighs ≈ parallel),             ≥ 160 = standing tall
//   pullup  see [PullupCounter]: hands fixed above the head, shoulders AND hips rise, chin over the hands, back to a
//           dead hang (elbows ≥ 150). Standing arm movements never move the body up with the hands still → 0 reps.
//   burpee  floor  = shoulder→ankle line within 40° of horizontal; finish = standing (knee ≥ 150, torso within 30°
//           of vertical) with both wrists above the nose, or a jump (ankles lift ≥ 6% of body height)
//   plank   see [PlankCounter]: timer runs only while shoulders, hips and ankles are in line, knees off the floor and
//           the shoulders are held up on the arms; it pauses on sag / pike / knees down and stops when the hold breaks.
// The gap between each "down" and "up" threshold is the hysteresis that stops jitter from double counting.

import 'dart:math' as math;

enum Joint {
  nose,
  leftShoulder,
  rightShoulder,
  leftElbow,
  rightElbow,
  leftWrist,
  rightWrist,
  leftHip,
  rightHip,
  leftKnee,
  rightKnee,
  leftAnkle,
  rightAnkle,
}

class Pt {
  const Pt(this.x, this.y, this.likelihood);
  final double x;
  final double y;
  final double likelihood;
}

typedef PoseFrame = Map<Joint, Pt>;

enum CueTone { info, good, warn }

class Cue {
  const Cue(this.text, this.tone);
  final String text;
  final CueTone tone;
}

/// Minimum ML Kit in-frame likelihood for a landmark to be trusted.
// inFrameLikelihood isn't an occlusion score and real side-on limbs often sit near 0.5, so the bar stays low.
const double kMinLikelihood = 0.3;

/// Interior angle ABC in degrees (0–180).
double angleAt(Pt a, Pt b, Pt c) {
  final abx = a.x - b.x, aby = a.y - b.y, cbx = c.x - b.x, cby = c.y - b.y;
  final dot = abx * cbx + aby * cby;
  final den = math.sqrt(abx * abx + aby * aby) * math.sqrt(cbx * cbx + cby * cby);
  if (den == 0) return 180;
  return math.acos((dot / den).clamp(-1.0, 1.0)) * 180 / math.pi;
}

/// Angle of the line a→b from the horizontal, 0–90°.
double tiltFromHorizontal(Pt a, Pt b) {
  final dx = (b.x - a.x).abs(), dy = (b.y - a.y).abs();
  return math.atan2(dy, dx) * 180 / math.pi;
}

double _dist(Pt a, Pt b) => math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

/// Exponential moving average with a reset when the signal disappears.
class _Ema {
  _Ema(this.alpha);
  final double alpha;
  double? v;
  double add(double x) => v = v == null ? x : v! + alpha * (x - v!);
  void reset() => v = null;
}

/// One side of the body (left or right) — the side facing the camera is usually far more reliable.
class BodySide {
  const BodySide(this.shoulder, this.elbow, this.wrist, this.hip, this.knee, this.ankle);
  final Joint shoulder, elbow, wrist, hip, knee, ankle;
}

const _left = BodySide(
  Joint.leftShoulder,
  Joint.leftElbow,
  Joint.leftWrist,
  Joint.leftHip,
  Joint.leftKnee,
  Joint.leftAnkle,
);
const _right = BodySide(
  Joint.rightShoulder,
  Joint.rightElbow,
  Joint.rightWrist,
  Joint.rightHip,
  Joint.rightKnee,
  Joint.rightAnkle,
);

abstract class RepCounter {
  RepCounter();

  factory RepCounter.forExercise(String id) => switch (id) {
    'pushups' => PushupCounter(),
    'squats' => SquatCounter(),
    'pullups' => PullupCounter(),
    'plank' => PlankCounter(),
    'burpees' => BurpeeCounter(),
    _ => throw ArgumentError('Unknown arena exercise $id'),
  };

  /// A fresh counter for the same exercise that keeps this one's score (reps / held seconds, partial reps, last rep
  /// time) but none of its tracking state. Used when the camera is switched mid-set: the new camera sees the body
  /// from another place, so baselines (top position, hang height…) must be learnt again.
  RepCounter carryOver(String exerciseId) {
    final n = RepCounter.forExercise(exerciseId);
    n.reps = reps;
    n.partialReps = partialReps;
    n._lastRepAt = _lastRepAt;
    return n;
  }

  /// When the last full rep was counted (stream time), null before the first one.
  Duration? get lastRepAt => _lastRepAt;

  /// Timed holds only: true once the member has clearly left the position, which ends the set.
  bool get holdBroken => false;

  /// Full-range reps (for plank: whole seconds held with good form).
  int get count => reps;
  int reps = 0;

  /// Reps rejected for range of motion or form.
  int partialReps = 0;

  /// Body visible with all landmarks this exercise needs.
  bool tracking = false;
  Cue cue = const Cue('Get into position', CueTone.info);

  /// Incremented whenever a full rep is counted — UI listens for changes to celebrate.
  int get repEvents => reps;

  Duration? _lastSeen;
  Duration? _lastRepAt;

  /// Feed one pose (null = no person detected) at stream time [t].
  void update(PoseFrame? pose, Duration t) {
    final ok = pose != null && process(pose, t);
    if (ok) {
      _lastSeen = t;
      tracking = true;
    } else if (_lastSeen == null || t - _lastSeen! > lostAfter) {
      if (tracking || cue.tone != CueTone.warn) cue = Cue(lostCue, CueTone.warn);
      tracking = false;
      onLost();
    }
  }

  /// Returns false when the landmarks this exercise needs are missing.
  bool process(PoseFrame pose, Duration t);

  String get lostCue => 'Step back — your whole body must be in the frame';

  /// How long the pose may be missing before the user is told tracking is lost.
  Duration get lostAfter => const Duration(milliseconds: 700);

  void onLost() {}

  /// Counts a rep unless it comes impossibly soon after the previous one (jitter guard).
  void countRep(Duration t, {String cue = 'Nice rep!'}) {
    if (_lastRepAt != null && t - _lastRepAt! < const Duration(milliseconds: 400)) return;
    _lastRepAt = t;
    reps++;
    this.cue = Cue(cue, CueTone.good);
  }

  void partial(String why) {
    partialReps++;
    cue = Cue(why, CueTone.warn);
  }

  /// Picks the body side whose [joints] are all confidently visible, preferring the higher mean likelihood.
  static BodySide? pickSide(PoseFrame p, List<Joint> Function(BodySide s) joints) {
    double score(BodySide s) {
      final js = joints(s);
      var sum = 0.0;
      for (final j in js) {
        final pt = p[j];
        if (pt == null || pt.likelihood < kMinLikelihood) return -1;
        sum += pt.likelihood;
      }
      return sum / js.length;
    }

    final l = score(_left), r = score(_right);
    if (l < 0 && r < 0) return null;
    return l >= r ? _left : _right;
  }

  static bool visible(PoseFrame p, Iterable<Joint> js) => js.every((j) => (p[j]?.likelihood ?? 0) >= kMinLikelihood);
}

/// Generic flex/extend counter: a rep is extended → flexed below [downAt] → extended above [upAt].
abstract class _FlexCounter extends RepCounter {
  _FlexCounter({required this.downAt, required this.upAt, required this.startAt});

  final double downAt;
  final double upAt;

  /// Below this angle the member has clearly started a rep (used to detect partial reps).
  final double startAt;

  final _angle = _Ema(0.5);
  bool _down = false;
  bool _armed = false; // seen the extended position at least once
  double _minSinceTop = 180;
  double _maxSinceBottom = 0;
  bool _formBroken = false;
  int _problemFrames = 0; // consecutive frames with a form problem; one noisy frame must not void a rep

  String get lowerCue;
  String get upCue;
  String get readyCue;

  /// The joint angle for this frame, or null when not measurable.
  double? measure(PoseFrame p);

  /// Extra form check during the rep (e.g. straight body for pushups). Return a cue when broken.
  String? formProblem(PoseFrame p) => null;

  @override
  void onLost() => _angle.reset();

  @override
  bool process(PoseFrame p, Duration t) {
    final raw = measure(p);
    if (raw == null) return false;
    final a = _angle.add(raw);
    final problem = formProblem(p);
    _problemFrames = problem == null ? 0 : _problemFrames + 1;
    final sustained = _problemFrames >= 3;

    if (!_armed) {
      if (a >= upAt && problem == null) {
        _armed = true;
        cue = Cue(readyCue, CueTone.info);
      } else {
        cue = Cue(problem ?? upCue, problem == null ? CueTone.info : CueTone.warn);
      }
      return true;
    }

    if (!_down) {
      _minSinceTop = math.min(_minSinceTop, a);
      if (sustained && a < startAt) _formBroken = true;
      if (a <= downAt) {
        _down = true;
        _maxSinceBottom = a;
      } else if (a >= upAt && _minSinceTop < startAt) {
        // Came back up without reaching depth.
        partial(lowerCue);
        _minSinceTop = 180;
        _formBroken = false;
      } else if (a >= upAt) {
        _minSinceTop = 180;
      }
    } else {
      if (sustained) _formBroken = true;
      if (a >= upAt) {
        if (_formBroken) {
          partial(formCueForPartial);
        } else {
          countRep(t);
        }
        _down = false;
        _formBroken = false;
        _minSinceTop = 180;
      } else {
        // Bounced: rose part-way, then went back down without locking out.
        if (_maxSinceBottom > startAt && a <= downAt) cue = Cue(upCue, CueTone.warn);
        _maxSinceBottom = a <= downAt ? a : math.max(_maxSinceBottom, a);
      }
    }
    if (problem != null && cue.tone != CueTone.warn) cue = Cue(problem, CueTone.warn);
    return true;
  }

  String get formCueForPartial => 'Keep good form for the whole rep';
}

/// Low-pass filter with a time constant, so behaviour does not change with frame rate (unlike a per-frame alpha).
class _TimeEma {
  _TimeEma(this.tauMs);
  final double tauMs;
  double? v;
  Duration? _at;
  double add(double x, Duration t) {
    final prev = v, at = _at;
    _at = t;
    if (prev == null || at == null) return v = x;
    final dt = (t - at).inMicroseconds / 1000.0;
    return v = prev + (1 - math.exp(-dt / tauMs)) * (x - prev);
  }

  void reset() {
    v = null;
    _at = null;
  }
}

/// Median of the last three samples: removes one-frame spikes without the lag of a heavier filter.
class _Median3 {
  final _b = <double>[];
  double add(double x) {
    _b.add(x);
    if (_b.length > 3) _b.removeAt(0);
    final s = [..._b]..sort();
    return s[s.length ~/ 2];
  }

  void reset() => _b.clear();
}

double _medianOf(List<double> xs) {
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

/// Pushups from any camera angle.
///
/// Signal: how far the shoulders drop, in torso lengths, where a torso length is measured so that it does not depend
/// on the camera azimuth: hypot(2D torso, 1.25 x 2D shoulder width). Side-on the first term dominates, head-on the
/// second. Shoulders are the steadiest landmarks in this pose, and arms cannot lower them without bending.
///
/// The 2D elbow angle does not decide depth: with flared elbows it stays near 170 degrees side-on even at the bottom.
/// It is only used side-on to confirm the arms straightened at the top.
/// Form is the median over a rep, so one bad frame cannot void it.
class PushupCounter extends RepCounter {
  // Distances are in torso lengths.
  static const double startDrop = 0.10; // the shoulders have clearly left the top
  static const double countDrop = 0.17; // deep enough: about 105-110 degrees of 3D elbow bend in simulation
  static const double topDrop = 0.07; // back at the top
  static const double bridgeDrop = 0.12; // this deep on both sides of a tracking gap: the bottom was in the gap
  static const double settleDrop = 0.05; // movement below this counts as holding still
  static const double sideOnFrom = 0.80; // 2D torso / torso length above which this is a side view
  static const double topElbow = 150; // side-on, the arms must open at least this far to finish a rep
  static const double minBodyLine = 140; // side-on, median shoulder-hip-foot over the rep
  static const double maxHandMove = 0.6; // hands moved this fraction of the shoulder drop: the camera or hands moved
  static const double kArm = 0.30; // landmark likelihoods: soft, because they do not measure occlusion
  static const double kLoose = 0.15; // below this, treat the landmark as out of frame

  final _shoulder = _Median3();
  final _shoulderSmooth = _TimeEma(80);
  final _elbow = _Median3();
  final _wrist = _Median3();
  final _scales = <double>[];
  Duration? _scaleAt;
  double _sideness = 1;

  double? _top; // shoulder y of the top position, in pixels (smaller y = higher)
  double? _settleY;
  Duration? _settleSince;
  double? _wristRef;
  double _handMove = 0;

  bool _inRep = false;
  double _depth = 0;
  final _bodyLine = <double>[];
  double? _stillY; // shoulder y when the body last moved, to spot someone resting mid-rep
  Duration? _stillSince;

  double _plankMs = 0;
  double _notPlankMs = 0;
  bool _plank = false;

  Duration? _lastT;
  double? _lastDrop;

  @override
  String get lostCue => 'Keep your shoulders and arms in the frame';

  @override
  Duration get lostAfter => const Duration(milliseconds: 1500);

  static Pt? _at(PoseFrame p, Joint j, double min) {
    final pt = p[j];
    return pt != null && pt.likelihood >= min ? pt : null;
  }

  static double? _midY(Pt? a, Pt? b) => a == null ? b?.y : (b == null ? a.y : (a.y + b.y) / 2);
  static double? _midX(Pt? a, Pt? b) => a == null ? b?.x : (b == null ? a.x : (a.x + b.x) / 2);

  void _resetRep() {
    _inRep = false;
    _depth = 0;
    _handMove = 0;
    _bodyLine.clear();
    _stillY = null;
    _stillSince = null;
  }

  void _resetAll() {
    _resetRep();
    _top = null;
    _settleY = null;
    _settleSince = null;
    _wristRef = null;
    _lastDrop = null;
    _shoulder.reset();
    _shoulderSmooth.reset();
    _elbow.reset();
    _wrist.reset();
  }

  @override
  bool process(PoseFrame p, Duration t) {
    final gapMs = _lastT == null ? 0.0 : (t - _lastT!).inMicroseconds / 1000.0;
    _lastT = t;
    if (gapMs > 4000) _resetAll(); // they left and came back: nothing before the gap carries over

    final ls = _at(p, Joint.leftShoulder, kArm), rs = _at(p, Joint.rightShoulder, kArm);
    if (ls == null && rs == null) return false;
    final shY = _midY(ls, rs)!, shX = _midX(ls, rs)!;

    final lh = _at(p, Joint.leftHip, kLoose), rh = _at(p, Joint.rightHip, kLoose);
    final hipY = _midY(lh, rh), hipX = _midX(lh, rh);

    // ---- scale
    final torso2d = hipY == null ? null : _dist(Pt(shX, shY, 1), Pt(hipX!, hipY, 1));
    final width2d = ls != null && rs != null ? _dist(ls, rs) : 0.0;
    if (torso2d != null && (_scaleAt == null || t - _scaleAt! >= const Duration(milliseconds: 200))) {
      final raw = math.sqrt(torso2d * torso2d + 1.5625 * width2d * width2d);
      if (raw > 0) {
        _scales.add(raw);
        if (_scales.length > 15) _scales.removeAt(0);
        _scaleAt = t;
      }
    }
    if (_scales.isEmpty) return false;
    final scale = _medianOf(_scales);
    if (torso2d != null) _sideness += 0.1 * ((torso2d / scale).clamp(0.0, 1.0) - _sideness);
    final sideOn = _sideness >= sideOnFrom;

    // ---- is this a plank, from any angle? (y grows downwards)
    final lw = _at(p, Joint.leftWrist, kArm), rw = _at(p, Joint.rightWrist, kArm);
    final wristRaw = _midY(lw, rw);
    final la = _at(p, Joint.leftAnkle, kLoose), ra = _at(p, Joint.rightAnkle, kLoose);
    final lk = _at(p, Joint.leftKnee, kLoose), rk = _at(p, Joint.rightKnee, kLoose);
    final footY = _midY(la, ra) ?? _midY(lk, rk);

    var plankNow = true;
    if (hipY != null && (hipY - shY) / scale > 0.6) plankNow = false; // torso upright: standing, sitting, kneeling
    if (hipY != null && footY != null && (footY - hipY) / scale > 0.9) plankNow = false; // legs under the hips
    if (wristRaw != null && (wristRaw - shY) / scale < 0.15) plankNow = false; // hands are not below the shoulders

    final stepMs = gapMs.clamp(0.0, 500.0);
    if (plankNow) {
      _plankMs += stepMs;
      _notPlankMs = 0;
    } else {
      _notPlankMs += stepMs;
      _plankMs = 0;
    }
    if (!_plank && _plankMs >= 350) {
      _plank = true;
    } else if (_plank && _notPlankMs >= 600) {
      _plank = false;
      _resetAll();
    }
    if (!_plank) {
      cue = const Cue('Get into a plank — hands on the floor', CueTone.info);
      return true;
    }

    final y = _shoulderSmooth.add(_shoulder.add(shY), t);
    final wristY = wristRaw == null ? null : _wrist.add(wristRaw);
    final rawElbow = _bestElbow(p);
    final elbow = rawElbow == null ? null : _elbow.add(rawElbow);

    // ---- learn the top once they hold still, so the move into position is not mistaken for it
    if (_top == null) {
      if (_settleY == null || (y - _settleY!).abs() / scale > settleDrop) {
        _settleY = y;
        _settleSince = t;
      } else if (t - _settleSince! >= const Duration(milliseconds: 300)) {
        _top = y;
        _wristRef = wristY;
        cue = const Cue('Ready — start your pushups', CueTone.info);
      }
      return true;
    }

    // ---- depth
    final top = _top!;
    if (y < top) {
      _top = top + 0.5 * (y - top);
    } else if (!_inRep) {
      // Slow drift so a shifted phone or body is absorbed. Frozen during a rep.
      _top = top + (1 - math.exp(-stepMs / 5000)) * (y - top);
    }
    final drop = (y - _top!) / scale;

    if (!_inRep) {
      if (wristY != null) {
        final ref = _wristRef;
        _wristRef = ref == null ? wristY : ref + (1 - math.exp(-stepMs / 1000)) * (wristY - ref);
      }
      if (drop >= startDrop) {
        _inRep = true;
        _depth = drop;
        _stillY = y;
        _stillSince = t;
      }
      _lastDrop = drop;
      return true;
    }

    // ---- inside a rep
    _depth = math.max(_depth, drop);
    final ref = _wristRef;
    if (wristY != null && ref != null) _handMove = math.max(_handMove, (wristY - ref).abs() / scale);
    final line = _bodyLineAngle(p);
    if (line != null) _bodyLine.add(line);

    // A dropout hid the bottom: deep on both sides of the gap means they went through it.
    final last = _lastDrop;
    if (gapMs >= 400 && last != null && last >= bridgeDrop && drop >= bridgeDrop) {
      _depth = math.max(_depth, countDrop);
    }
    _lastDrop = drop;

    if ((y - _stillY!).abs() / scale > settleDrop) {
      _stillY = y;
      _stillSince = t;
    } else if (t - _stillSince! > const Duration(seconds: 6)) {
      // Resting low down. Only stillness rebases the top, so pulsing near the bottom never becomes a new "top".
      _resetRep();
      _top = y;
      cue = const Cue('Push up to continue', CueTone.info);
      return true;
    }

    if (drop <= topDrop) {
      if (sideOn && elbow != null && elbow < topElbow) {
        cue = const Cue('Straighten your arms', CueTone.info);
        return true; // shoulders are up but the arms are still bent: stay in the rep
      }
      if (_depth < countDrop) {
        partial('Go lower — chest toward the floor');
      } else if (_handMove >= maxHandMove * _depth) {
        partial('Keep your hands and the phone still');
      } else if (sideOn && _bodyLine.length >= 3 && _medianOf(_bodyLine) < minBodyLine) {
        partial('Keep your body straight — rep not counted');
      } else {
        countRep(t);
      }
      _resetRep();
    } else if (_depth >= countDrop && cue.tone != CueTone.warn) {
      cue = const Cue('Push up', CueTone.info);
    }
    return true;
  }

  /// Elbow angle of the arm with the best likelihood, or null when neither arm is usable.
  double? _bestElbow(PoseFrame p) {
    double? best;
    var bestScore = kArm;
    for (final s in const [_left, _right]) {
      final a = _at(p, s.shoulder, kArm), b = _at(p, s.elbow, kArm), c = _at(p, s.wrist, kArm);
      if (a == null || b == null || c == null) continue;
      final score = math.min(a.likelihood, math.min(b.likelihood, c.likelihood));
      if (score > bestScore) {
        bestScore = score;
        best = angleAt(a, b, c);
      }
    }
    return best;
  }

  /// Shoulder-hip-foot angle on the side with the best likelihood.
  double? _bodyLineAngle(PoseFrame p) {
    double? best;
    var bestScore = kArm;
    for (final s in const [_left, _right]) {
      final a = _at(p, s.shoulder, kArm), b = _at(p, s.hip, kArm);
      final c = _at(p, s.ankle, kArm) ?? _at(p, s.knee, kArm);
      if (a == null || b == null || c == null) continue;
      final score = math.min(b.likelihood, c.likelihood);
      if (score > bestScore) {
        bestScore = score;
        best = angleAt(a, b, c);
      }
    }
    return best;
  }
}

class SquatCounter extends _FlexCounter {
  SquatCounter() : super(downAt: 100, upAt: 160, startAt: 145);

  @override
  String get lowerCue => 'Go lower! Thighs to parallel';
  @override
  String get upCue => 'Stand all the way up';
  @override
  String get readyCue => 'Standing tall — start squatting';
  @override
  String get lostCue => 'Step back — hips, knees and feet must be visible';

  @override
  double? measure(PoseFrame p) {
    final s = RepCounter.pickSide(p, (s) => [s.hip, s.knee, s.ankle]);
    if (s == null) return null;
    return angleAt(p[s.hip]!, p[s.knee]!, p[s.ankle]!);
  }
}

/// Pullups, phone propped up in front of the bar (straight on or at an angle).
///
/// What separates a pullup from copying the arm movement: the hands hold a fixed bar, so during a real rep the hands
/// stay still in the image while the shoulders AND the hips (and the feet, when they are in view) rise by most of a
/// torso length. Standing and waving the arms moves the hands, not the body; squatting under a low bar and standing
/// up lifts the hips but leaves the knees and feet where they were. Neither is counted. The legs (knees or ankles) must
/// be in view, because they are what proves the feet left the floor.
///
/// One rep = dead hang (hands above the head, arms straight) → pull until the nose is clearly above the hands (chin at
/// or over the bar) → lower back to straight arms.
class PullupCounter extends RepCounter {
  // Distances are in torso lengths (shoulder to hip, about 0.5 m on an adult).
  static const double hangElbow = 150; // arms straight enough for a dead hang
  static const double handsOverHead = 0.10; // hands at least this far above the nose = hanging from something
  static const double startRise = 0.15; // shoulders have clearly left the hang
  static const double topMargin = 0.16; // nose this far above the hands (~8 cm) = chin at or over the bar
  static const double minShoulderRise = 0.45; // a real rep lifts the shoulders by about 0.8-1 torso
  static const double minHipRise = 0.35; // ...and the hips with them
  static const double minLegRise = 0.30; // ...and the legs (knees / ankles): the feet are off the floor
  static const double maxThighGrow = 0.45; // hip–knee gap opening this much = standing up out of a squat
  static const double maxHandMove = 0.25; // hands on a bar barely move; waving hands move a full forearm
  static const double letGo = 0.55; // hands moved this far from the bar position: they let go / are not hanging
  static const double backDown = 0.20; // shoulders back within this of the hang = the rep is over
  static const double kNeed = 0.30;

  final _elbow = _Median3();
  final _sh = _Median3();
  final _hip = _Median3();
  final _wr = _Median3();
  final _nose = _Median3();
  final _ank = _Median3();
  final _knee = _Median3();
  final _torsos = <double>[];
  Duration? _torsoAt;
  Duration? _lastT;

  Duration? _hangSince; // hanging still (arms straight, shoulders not moving) since
  double _settleSh = 0;
  Duration? _stuckSince; // straight arms but not back at the reference: the hang height changed
  bool _armed = false;
  double _shRef = 0, _hipRef = 0, _wrRef = 0;
  double? _ankRef, _kneeRef;

  bool _inRep = false;
  bool _top = false;
  double _shRise = 0, _hipRise = 0, _handMove = 0;
  double? _legRise, _ankBest, _kneeBest;
  double _thighGrow = 0;

  @override
  String get lostCue => 'Step back — head, hands and hips must be visible';

  @override
  Duration get lostAfter => const Duration(milliseconds: 1500);

  /// Losing sight of the body ends the current rep (its top can't be verified), but the bar does not move, so the
  /// hang reference survives short gaps; only a long one (see [process]) starts over.
  @override
  void onLost() {
    _inRep = false;
    _top = false;
    _stuckSince = null;
    for (final m in [_elbow, _sh, _hip, _wr, _nose, _ank, _knee]) {
      m.reset();
    }
  }

  void _reset() {
    _armed = false;
    _inRep = false;
    _top = false;
    _hangSince = null;
    _ankRef = null;
    _kneeRef = null;
    for (final m in [_elbow, _sh, _hip, _wr, _nose, _ank, _knee]) {
      m.reset();
    }
  }

  static double? _y(PoseFrame p, Iterable<Joint> js, {double min = kNeed}) {
    var sum = 0.0, n = 0;
    for (final j in js) {
      final pt = p[j];
      if (pt != null && pt.likelihood >= min) {
        sum += pt.y;
        n++;
      }
    }
    return n == 0 ? null : sum / n;
  }

  @override
  bool process(PoseFrame p, Duration t) {
    final gap = _lastT == null ? Duration.zero : t - _lastT!;
    _lastT = t;
    if (gap > const Duration(seconds: 4)) _reset();

    final noseRaw = _y(p, const [Joint.nose]);
    final shRaw = _y(p, const [Joint.leftShoulder, Joint.rightShoulder]);
    final wrRaw = _y(p, const [Joint.leftWrist, Joint.rightWrist]);
    final hipRaw = _y(p, const [Joint.leftHip, Joint.rightHip]);
    if (noseRaw == null || shRaw == null || wrRaw == null || hipRaw == null) return false;
    var elbowSum = 0.0, elbowN = 0;
    for (final s in const [_left, _right]) {
      if (!RepCounter.visible(p, [s.shoulder, s.elbow, s.wrist])) continue;
      elbowSum += angleAt(p[s.shoulder]!, p[s.elbow]!, p[s.wrist]!);
      elbowN++;
    }
    if (elbowN == 0) return false;
    final ankRaw = _y(p, const [Joint.leftAnkle, Joint.rightAnkle]);
    final kneeRaw = _y(p, const [Joint.leftKnee, Joint.rightKnee]);

    final nose = _nose.add(noseRaw), sh = _sh.add(shRaw), wr = _wr.add(wrRaw), hip = _hip.add(hipRaw);
    final elbow = _elbow.add(elbowSum / elbowN);
    final ank = ankRaw == null ? null : _ank.add(ankRaw);
    final knee = kneeRaw == null ? null : _knee.add(kneeRaw);

    // Torso length in pixels (median, so a bent-over frame or a jitter spike does not change the scale).
    if (_torsoAt == null || t - _torsoAt! >= const Duration(milliseconds: 150)) {
      final torso = (hip - sh).abs();
      if (torso > 0) {
        _torsos.add(torso);
        if (_torsos.length > 21) _torsos.removeAt(0);
        _torsoAt = t;
      }
    }
    if (_torsos.isEmpty) return false;
    final torso = _medianOf(_torsos);

    final hanging = wr < nose - handsOverHead * torso && wr < sh;
    final straight = elbow >= hangElbow;

    if (!_inRep) {
      if (hanging && straight) {
        // Settled = the shoulders stayed within a small band, so jumping up to the bar is not taken as the hang.
        if (_hangSince == null || (sh - _settleSh).abs() / torso > 0.06) {
          _hangSince = t;
          _settleSh = sh;
        }
        if (!_armed && t - _hangSince! >= const Duration(milliseconds: 300)) {
          if (ank == null && knee == null) {
            cue = const Cue('Step back — your legs must be in the frame too', CueTone.warn);
            return true;
          }
          _armed = true;
          _shRef = sh;
          _hipRef = hip;
          _wrRef = wr;
          _ankRef = ank;
          _kneeRef = knee;
          cue = const Cue('Dead hang — now pull!', CueTone.info);
        } else if (_armed) {
          // Follow the hang slowly: the body sways and the grip shifts a little between reps.
          final k = 1 - math.exp(-gap.inMicroseconds / 400000);
          _shRef += k * (sh - _shRef);
          _hipRef += k * (hip - _hipRef);
          _wrRef += k * (wr - _wrRef);
          if (ank != null) _ankRef = _ankRef == null ? ank : _ankRef! + k * (ank - _ankRef!);
          if (knee != null) _kneeRef = _kneeRef == null ? knee : _kneeRef! + k * (knee - _kneeRef!);
        }
      } else {
        _hangSince = null;
      }
      if (!_armed) {
        cue = hanging
            ? const Cue('Straighten your arms — start from a dead hang', CueTone.info)
            : const Cue('Hang from the bar — hands above your head', CueTone.info);
        return true;
      }
      if ((wr - _wrRef).abs() / torso > letGo) {
        // The hands moved, not the body: arm waving, or they let go of the bar.
        _armed = false;
        _hangSince = null;
        cue = const Cue('Hang from the bar — arm movements alone do not count', CueTone.warn);
        return true;
      }
      final rise = (_shRef - sh) / torso;
      if (rise >= startRise) {
        _inRep = true;
        _top = false;
        _stuckSince = null;
        _shRise = rise;
        _hipRise = (_hipRef - hip) / torso;
        _handMove = (wr - _wrRef).abs() / torso;
        _legRise = _ankBest = _kneeBest = null;
        _thighGrow = 0;
        _noteLegs(ank, knee, hip, rise, torso);
      } else if (elbow < 110 && rise < 0.08) {
        cue = const Cue('Pull your body up — the hands stay on the bar', CueTone.warn);
      }
      return true;
    }

    // ---- inside a rep
    final rise = (_shRef - sh) / torso;
    _shRise = math.max(_shRise, rise);
    _hipRise = math.max(_hipRise, (_hipRef - hip) / torso);
    _handMove = math.max(_handMove, (wr - _wrRef).abs() / torso);
    _noteLegs(ank, knee, hip, rise, torso);
    // The top lasts only a few frames on a slow phone and a median would clip it, so a single confident raw frame
    // (nose and both hands clearly tracked) is enough.
    if (nose <= wr - topMargin * torso) _top = true;
    final wrSure = _y(p, const [Joint.leftWrist, Joint.rightWrist], min: 0.5);
    final noseSure = _y(p, const [Joint.nose], min: 0.5);
    if (wrSure != null && noseSure != null && noseSure <= wrSure - topMargin * torso) _top = true;

    if (_handMove > letGo) {
      _inRep = false;
      _armed = false;
      _hangSince = null;
      cue = const Cue('Keep your hands on the bar', CueTone.warn);
      return true;
    }

    // Back in a straight-arm hang, but higher than the reference: the reference was taken too low (still getting
    // onto the bar) or they re-gripped. This IS the bottom of the rep: move the reference here and judge the rep
    // with its rises measured from the new hang height.
    var atBottom = rise <= backDown && straight;
    if (straight && hanging && rise > backDown) {
      _stuckSince ??= t;
      if (t - _stuckSince! >= const Duration(milliseconds: 350)) {
        final dHip = (_hipRef - hip) / torso;
        _shRise -= rise;
        _hipRise -= dHip;
        if (_legRise != null) _legRise = _legRise! - rise;
        _thighGrow = 0;
        _shRef = sh;
        _hipRef = hip;
        _wrRef = wr;
        if (ank != null) _ankRef = ank;
        if (knee != null) _kneeRef = knee;
        _stuckSince = null;
        atBottom = true;
      }
    } else {
      _stuckSince = null;
    }

    if (atBottom) {
      if (!_top) {
        if (_shRise >= 0.3) partial('Chin over the bar!');
      } else if (_handMove > maxHandMove) {
        partial('Keep your hands on the bar');
      } else if (_shRise < minShoulderRise || _hipRise < minHipRise) {
        partial('Pull your whole body up — arm movements alone do not count');
      } else if ((_legRise ?? 0) < minLegRise || _thighGrow > maxThighGrow) {
        partial('Feet off the floor — legs must rise with you');
      } else {
        countRep(t, cue: 'Clean pullup!');
      }
      _inRep = false;
      _top = false;
      _hangSince = t; // already back in the hang
      _settleSh = sh;
    } else if (_top) {
      cue = const Cue('Lower all the way — straighten your arms', CueTone.info);
    } else if (_shRise >= 0.3 && rise < _shRise - 0.2) {
      cue = const Cue('Chin over the bar!', CueTone.warn);
    }
    return true;
  }

  /// How far the legs rose since the rep started: the smaller of the knees' and the ankles' best rise (each one that
  /// is visible must rise — squatting moves the knees a little but leaves the ankles on the floor), and the thighs
  /// must not "grow" (hip–knee gap opening up = standing up out of a squat, not pulling).
  /// A joint only takes part once it was seen while the shoulders were well up, so a foot that dropped out of
  /// tracking for the top of the rep is not mistaken for a foot that stayed on the floor.
  void _noteLegs(double? ank, double? knee, double hip, double shRise, double torso) {
    final up = shRise >= 0.4;
    if (up && ank != null && _ankRef != null) _ankBest = math.max(_ankBest ?? -1, (_ankRef! - ank) / torso);
    if (up && knee != null && _kneeRef != null) _kneeBest = math.max(_kneeBest ?? -1, (_kneeRef! - knee) / torso);
    if (knee != null && _kneeRef != null) {
      _thighGrow = math.max(_thighGrow, ((knee - hip) - (_kneeRef! - _hipRef)) / torso);
    }
    final rises = [?_ankBest, ?_kneeBest];
    _legRise = rises.isEmpty ? null : rises.reduce(math.min);
  }
}

class BurpeeCounter extends RepCounter {
  // floor reached since the last counted rep
  bool _floor = false;
  bool _crouched = false;
  bool _armed = false;
  double? _standAnkleY;
  double _bodyH = 0;

  @override
  bool process(PoseFrame p, Duration t) {
    final s = RepCounter.pickSide(p, (s) => [s.shoulder, s.hip, s.knee, s.ankle]);
    if (s == null) return false;
    final sh = p[s.shoulder]!, hip = p[s.hip]!, knee = p[s.knee]!, an = p[s.ankle]!;

    final kneeAngle = angleAt(hip, knee, an);
    final torsoFromVertical = 90 - tiltFromHorizontal(sh, hip);
    final bodyFromHorizontal = tiltFromHorizontal(sh, an);
    final standing = kneeAngle >= 150 && torsoFromVertical <= 30;
    final onFloor = bodyFromHorizontal <= 40;

    final wristsVisible = RepCounter.visible(p, const [Joint.leftWrist, Joint.rightWrist, Joint.nose]);
    final overhead =
        wristsVisible && p[Joint.leftWrist]!.y < p[Joint.nose]!.y && p[Joint.rightWrist]!.y < p[Joint.nose]!.y;

    if (standing) {
      final h = _dist(sh, an);
      if (_standAnkleY == null || !_floor) {
        // Track the resting ankle height while standing (smoothed) to detect jumps.
        _standAnkleY = _standAnkleY == null ? an.y : _standAnkleY! * 0.8 + an.y * 0.2;
        _bodyH = h;
      }
    }
    final jumped = _standAnkleY != null && _bodyH > 0 && (_standAnkleY! - an.y) > 0.06 * _bodyH;

    if (!_armed) {
      if (standing) {
        _armed = true;
        cue = const Cue('Standing tall — go!', CueTone.info);
      } else {
        cue = const Cue('Stand tall to start', CueTone.info);
      }
      return true;
    }

    if (!_floor) {
      if (onFloor) {
        _floor = true;
        _crouched = false;
        cue = const Cue('Now jump up — hands overhead', CueTone.info);
      } else if (!standing && (kneeAngle < 120 || torsoFromVertical > 45)) {
        _crouched = true;
      } else if (standing && _crouched) {
        partial('Kick back all the way to a plank');
        _crouched = false;
      }
    } else if (standing && (overhead || jumped)) {
      countRep(t, cue: 'Burpee! Keep going');
      _floor = false;
    } else if (standing) {
      cue = const Cue('Hands overhead to finish the rep!', CueTone.warn);
    }
    return true;
  }
}

/// Plank hold timer (forearm or straight-arm plank, phone side-on).
///
/// The timer runs only while the hold is good: shoulders, hips and ankles in one straight line, knees off the floor
/// and the shoulders held up on the forearms / hands. It pauses the moment the hips sag or pike or the knees touch
/// down, and the hold is over ([holdBroken]) once the member leaves the plank (stands, sits, lies down, walks off).
///
/// Distances are in body lengths (shoulder to ankle in the image, about 1.35 m on an adult):
///   hip sag   hip below the shoulder–ankle line: > 0.065 pauses (≈ 9 cm, body line ≈ 164°), < 0.045 resumes
///   hip pike  hip above the line: > 0.085 pauses (≈ 12 cm), < 0.06 resumes — a slight pike is normal and safe
///   knees     knee height above the elbow/hand–ankle floor line: < 0.025 = knees down (a plank holds ≈ 0.07)
///   support   shoulders above the forearms / hands by ≥ 0.10 (lying flat on the floor ≈ 0)
///   tilt      shoulder→ankle within 35° of horizontal (standing ≈ 90°)
/// Changes of state need 250 ms of agreement, so one noisy frame neither pauses nor resumes the timer; the delays
/// on the way in and out cancel out, so a 60 s hold reads 60 s.
class PlankCounter extends RepCounter {
  static const double pauseSag = 0.065, resumeSag = 0.045;
  static const double pausePike = 0.085, resumePike = 0.06;
  static const double kneesDown = 0.025, kneesUp = 0.04;
  static const double minSupport = 0.10;
  static const double maxTilt = 35;
  static const Duration debounce = Duration(milliseconds: 250);
  static const Duration leaveAfter = Duration(milliseconds: 1200); // out of plank this long = hold broken
  static const Duration lostBreak = Duration(seconds: 3); // out of view this long = hold broken
  static const Duration maxPause = Duration(seconds: 15); // paused for bad form this long = hold broken
  static const Duration maxBridge = Duration(milliseconds: 1500); // tracking gaps up to this are bridged

  final _dev = _Median3();
  final _devS = _TimeEma(150);
  final _knee = _Median3();
  final _kneeS = _TimeEma(150);
  final _support = _Median3();
  final _tilt = _Median3();

  double heldSeconds = 0;
  bool _good = false;
  bool _posture = false;
  bool _kneesOk = true;
  Duration? _pendingSince;
  Duration? _lastT;
  Duration? _offSince; // left the plank posture
  Duration? _pausedSince; // in posture but bad form
  bool _broken = false;
  bool _started = false;

  /// Last measured hip offset from the line in body lengths (positive = sagging), for diagnostics and tests.
  double hipOffset = 0;

  /// Whether the timer is running right now.
  bool get running => _good && !_broken;

  @override
  int get reps => heldSeconds.floor();
  @override
  set reps(int v) {}

  @override
  bool get holdBroken => _broken;

  @override
  RepCounter carryOver(String exerciseId) => PlankCounter()
    ..heldSeconds = heldSeconds
    ..partialReps = partialReps
    .._started = _started;

  @override
  String get lostCue => 'Phone to your side — shoulders to ankles in the frame';

  @override
  Duration get lostAfter => const Duration(milliseconds: 1500);

  @override
  void update(PoseFrame? pose, Duration t) {
    super.update(pose, t);
    if (_started && !tracking && _lastSeen != null && t - _lastSeen! > lostBreak) _broken = true;
  }

  @override
  void onLost() {
    _good = false;
    _kneesOk = true;
    _pendingSince = null;
    _lastT = null;
    for (final m in [_dev, _knee, _support, _tilt]) {
      m.reset();
    }
    _devS.reset();
    _kneeS.reset();
  }

  static Pt? _at(PoseFrame p, Joint j) {
    final pt = p[j];
    return pt != null && pt.likelihood >= kMinLikelihood ? pt : null;
  }

  /// Signed distance of [q] from the line a→b, in units of [len]: positive = lower in the image (y grows down).
  static double _below(Pt a, Pt b, Pt q, double len) {
    final dx = b.x - a.x, dy = b.y - a.y;
    final cross = dx * (q.y - a.y) - dy * (q.x - a.x);
    final l = math.sqrt(dx * dx + dy * dy);
    if (l == 0 || len == 0) return 0;
    return (dx >= 0 ? 1 : -1) * cross / l / len;
  }

  @override
  bool process(PoseFrame p, Duration t) {
    if (_broken) {
      cue = const Cue('Hold over — great effort!', CueTone.info);
      return true;
    }
    // The side facing the camera: shoulder, hip and ankle (or the knee when the feet are cut off).
    BodySide? side;
    var best = -1.0;
    var useKnee = false;
    for (final s in const [_left, _right]) {
      final sh = _at(p, s.shoulder), hip = _at(p, s.hip), an = _at(p, s.ankle), kn = _at(p, s.knee);
      if (sh == null || hip == null) continue;
      final end = an ?? kn;
      if (end == null) continue;
      final score = (sh.likelihood + hip.likelihood + end.likelihood) / 3 + (an != null ? 0.2 : 0);
      if (score > best) {
        best = score;
        side = s;
        useKnee = an == null;
      }
    }
    if (side == null) return false;
    final sh = p[side.shoulder]!, hip = p[side.hip]!;
    final end = useKnee ? p[side.knee]! : p[side.ankle]!;
    final len = _dist(sh, end);
    if (len <= 0) return false;

    final tilt = _tilt.add(tiltFromHorizontal(sh, end));
    final dev = _devS.add(_dev.add(_below(sh, end, hip, len)), t);
    hipOffset = dev;

    // Floor contact: the lower of elbow / wrist (forearm plank: both on the floor; straight arms: the hand).
    Pt? support;
    for (final s in [side, side == _left ? _right : _left]) {
      for (final j in [s.elbow, s.wrist]) {
        final q = _at(p, j);
        if (q != null && (support == null || q.y > support.y)) support = q;
      }
      if (support != null) break;
    }
    double? supportLift;
    if (support != null) supportLift = _support.add((support.y - sh.y) / len);

    double? kneeLift;
    final knee = _at(p, side.knee);
    if (!useKnee && knee != null && support != null) {
      kneeLift = _kneeS.add(_knee.add(-_below(support, end, knee, len)), t);
    }

    // ---- posture: is this a plank at all?
    if (supportLift != null) {
      _posture = tilt <= maxTilt && supportLift >= minSupport;
    } else {
      _posture = _posture && tilt <= maxTilt; // arms hidden: keep the last verdict while the body stays low
    }

    // ---- form (hysteresis: harder to start than to keep going)
    final sagOk = _good ? dev <= pauseSag : dev <= resumeSag;
    final pikeOk = _good ? dev >= -pausePike : dev >= -resumePike;
    // Knee not measurable this frame (dropout, feet cut off): keep the last verdict rather than assume it is up.
    final kneesOk = kneeLift == null ? _kneesOk : (_good ? kneeLift >= kneesDown : kneeLift >= kneesUp);
    _kneesOk = kneesOk;
    final want = _posture && sagOk && pikeOk && kneesOk;

    final wasGood = _good;
    if (want != _good) {
      _pendingSince ??= t;
      if (t - _pendingSince! >= debounce) {
        _good = want;
        _pendingSince = null;
      }
    } else {
      _pendingSince = null;
    }

    final last = _lastT;
    _lastT = t;
    if (wasGood && last != null) {
      final dt = t - last;
      if (dt <= maxBridge) heldSeconds += dt.inMicroseconds / 1e6;
    }
    if (heldSeconds >= 1) _started = true;
    if (wasGood && !_good) partialReps++; // form breaks

    // ---- has the hold ended?
    if (_posture) {
      _offSince = null;
    } else {
      _offSince ??= t;
    }
    if (_good || !_posture) {
      _pausedSince = null;
    } else {
      _pausedSince ??= t;
    }
    final left = _offSince != null && t - _offSince! >= leaveAfter;
    final gaveUp = _pausedSince != null && t - _pausedSince! >= maxPause;
    if (_started && (left || gaveUp)) {
      _broken = true;
      _good = false;
      cue = const Cue('Hold over — great effort!', CueTone.info);
      return true;
    }

    // ---- cue
    if (_good) {
      cue = const Cue('Perfect line — hold it!', CueTone.good);
    } else if (!_posture) {
      cue = _started
          ? const Cue('Timer paused — get back into your plank', CueTone.warn)
          : const Cue('Get into a plank — forearms on the floor', CueTone.info);
    } else if (!sagOk) {
      cue = const Cue('Hips sagging — timer paused', CueTone.warn);
    } else if (!pikeOk) {
      cue = const Cue('Hips too high — timer paused', CueTone.warn);
    } else if (!kneesOk) {
      cue = const Cue('Knees off the floor — timer paused', CueTone.warn);
    } else {
      cue = const Cue('Hold still — straight line…', CueTone.info);
    }
    return true;
  }
}

/// When an Unlimited ProveIt set ends by itself: one continuous set, no target.
///  - reps: [idle] without a new full rep (partial reps do not keep the set alive);
///  - plank: as soon as the hold breaks;
///  - nobody started: [firstRepWithin] after the countdown without a first rep / first second held.
class UnlimitedSetRule {
  static const Duration idle = Duration(seconds: 5);
  static const Duration firstRepWithin = Duration(seconds: 20);

  static bool shouldEnd(RepCounter c, Duration elapsed) {
    if (c is PlankCounter) return c.holdBroken || (c.heldSeconds < 1 && elapsed >= firstRepWithin);
    final last = c.lastRepAt;
    if (last == null) return elapsed >= firstRepWithin;
    return elapsed - last >= idle;
  }

  /// Time left before the set ends on its own, or null when that does not apply (a plank already under way).
  static Duration? remaining(RepCounter c, Duration elapsed) {
    if (c is PlankCounter) {
      if (c.heldSeconds >= 1) return null;
      final left = firstRepWithin - elapsed;
      return left.isNegative ? Duration.zero : left;
    }
    final last = c.lastRepAt;
    final left = last == null ? firstRepWithin - elapsed : idle - (elapsed - last);
    return left.isNegative ? Duration.zero : left;
  }
}
