// AI Arena rep counting: pure Dart state machines over pose landmarks (no Flutter / ML Kit imports, so the
// logic can be simulated and unit-tested off-device).
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
//   pullup  top    = nose above the wrists (chin over the bar),   bottom = elbows ≥ 150 (dead hang)
//   burpee  floor  = shoulder→ankle line within 40° of horizontal; finish = standing (knee ≥ 150, torso within 30°
//           of vertical) with both wrists above the nose, or a jump (ankles lift ≥ 6% of body height)
//   plank   body   ≥ 162 to (re)start the timer, < 155 pauses it (hysteresis), body within 40° of horizontal
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
const double kMinLikelihood = 0.5;

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

const _left = BodySide(Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist, Joint.leftHip, Joint.leftKnee, Joint.leftAnkle);
const _right =
    BodySide(Joint.rightShoulder, Joint.rightElbow, Joint.rightWrist, Joint.rightHip, Joint.rightKnee, Joint.rightAnkle);

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
    } else if (_lastSeen == null || t - _lastSeen! > const Duration(milliseconds: 700)) {
      if (tracking || cue.tone != CueTone.warn) cue = Cue(lostCue, CueTone.warn);
      tracking = false;
      onLost();
    }
  }

  /// Returns false when the landmarks this exercise needs are missing.
  bool process(PoseFrame pose, Duration t);

  String get lostCue => 'Step back — your whole body must be in the frame';

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

  static bool visible(PoseFrame p, Iterable<Joint> js) =>
      js.every((j) => (p[j]?.likelihood ?? 0) >= kMinLikelihood);
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
      if (problem != null && a < startAt) _formBroken = true;
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
      if (problem != null) _formBroken = true;
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

class PushupCounter extends _FlexCounter {
  PushupCounter() : super(downAt: 95, upAt: 158, startAt: 140);

  BodySide? _side;

  @override
  String get lowerCue => 'Go lower! Elbows past 90°';
  @override
  String get upCue => 'Push all the way up — lock your arms';
  @override
  String get readyCue => 'Plank position locked — start your pushups';
  @override
  String get formCueForPartial => 'Keep your body straight — rep not counted';
  @override
  String get lostCue => 'Phone to your side — whole body in the frame';

  @override
  double? measure(PoseFrame p) {
    _side = RepCounter.pickSide(p, (s) => [s.shoulder, s.elbow, s.wrist, s.hip, s.ankle]);
    final s = _side;
    if (s == null) return null;
    return angleAt(p[s.shoulder]!, p[s.elbow]!, p[s.wrist]!);
  }

  @override
  String? formProblem(PoseFrame p) {
    final s = _side!;
    final sh = p[s.shoulder]!, hip = p[s.hip]!, an = p[s.ankle]!;
    if (tiltFromHorizontal(sh, an) > 50) return 'Get down into a plank position';
    if (angleAt(sh, hip, an) < 145) {
      // Hip below the shoulder–ankle line (larger y) = sagging.
      final lineY = sh.y + (an.y - sh.y) * ((hip.x - sh.x) / ((an.x - sh.x) == 0 ? 1 : (an.x - sh.x)));
      return hip.y > lineY ? 'Hips are sagging — brace your core' : 'Hips too high — straighten your body';
    }
    return null;
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

class PullupCounter extends RepCounter {
  final _elbow = _Ema(0.5);
  bool _armed = false; // seen a dead hang
  bool _top = false;
  bool _pulled = false; // started pulling since the last hang

  @override
  String get lostCue => 'Step back — head, hands and hips must be visible';

  @override
  void onLost() => _elbow.reset();

  @override
  bool process(PoseFrame p, Duration t) {
    const need = [
      Joint.nose,
      Joint.leftShoulder,
      Joint.rightShoulder,
      Joint.leftElbow,
      Joint.rightElbow,
      Joint.leftWrist,
      Joint.rightWrist,
    ];
    if (!RepCounter.visible(p, need)) return false;
    final elbow = _elbow.add((angleAt(p[Joint.leftShoulder]!, p[Joint.leftElbow]!, p[Joint.leftWrist]!) +
            angleAt(p[Joint.rightShoulder]!, p[Joint.rightElbow]!, p[Joint.rightWrist]!)) /
        2);
    final wristY = (p[Joint.leftWrist]!.y + p[Joint.rightWrist]!.y) / 2;
    final shoulderY = (p[Joint.leftShoulder]!.y + p[Joint.rightShoulder]!.y) / 2;
    final noseY = p[Joint.nose]!.y;

    if (wristY > shoulderY) {
      cue = const Cue('Grab the bar — hands above your head', CueTone.info);
      return true;
    }
    final hang = elbow >= 150;
    final chinOver = noseY < wristY;

    if (!_armed) {
      if (hang) {
        _armed = true;
        cue = const Cue('Dead hang — pull!', CueTone.info);
      } else {
        cue = const Cue('Start from a dead hang, arms straight', CueTone.info);
      }
      return true;
    }
    if (!_top) {
      if (elbow < 120) _pulled = true;
      if (chinOver) {
        _top = true;
      } else if (hang && _pulled) {
        partial('Chin over the bar!');
        _pulled = false;
      }
    } else if (hang) {
      countRep(t);
      _top = false;
      _pulled = false;
    } else if (!chinOver && elbow < 150) {
      cue = const Cue('Lower all the way — straighten your arms', CueTone.info);
    }
    return true;
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

class PlankCounter extends RepCounter {
  final _body = _Ema(0.5);
  bool _good = false;
  Duration? _lastT;
  double heldSeconds = 0;

  @override
  int get reps => heldSeconds.floor();
  @override
  set reps(int v) {}

  @override
  String get lostCue => 'Phone to your side — shoulders to ankles in the frame';

  @override
  void onLost() {
    _good = false;
    _lastT = null;
    _body.reset();
  }

  @override
  bool process(PoseFrame p, Duration t) {
    final s = RepCounter.pickSide(p, (s) => [s.shoulder, s.hip, s.ankle]);
    if (s == null) return false;
    final sh = p[s.shoulder]!, hip = p[s.hip]!, an = p[s.ankle]!;
    final body = _body.add(angleAt(sh, hip, an));
    final horizontal = tiltFromHorizontal(sh, an) <= 40;

    final wasGood = _good;
    if (!horizontal) {
      _good = false;
    } else if (_good) {
      _good = body >= 155;
    } else {
      _good = body >= 162;
    }

    if (_good && wasGood && _lastT != null) {
      // Cap the step so a stalled stream never adds a big jump.
      final dt = (t - _lastT!).inMicroseconds / 1e6;
      heldSeconds += dt.clamp(0, 0.5);
    }
    _lastT = t;

    if (_good) {
      cue = const Cue('Perfect line — hold it!', CueTone.good);
    } else if (!horizontal) {
      cue = Cue(heldSeconds > 0 ? 'Timer paused — get back into your plank' : 'Get down into a plank', CueTone.warn);
    } else {
      final lineY = sh.y + (an.y - sh.y) * ((hip.x - sh.x) / ((an.x - sh.x) == 0 ? 1 : (an.x - sh.x)));
      cue = Cue(hip.y > lineY ? 'Hips sagging — timer paused' : 'Hips too high — timer paused', CueTone.warn);
    }
    if (wasGood && !_good) partialReps++; // number of form breaks
    return true;
  }
}
