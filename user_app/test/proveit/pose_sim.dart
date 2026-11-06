// Noisy pose simulation for the ProveIt counters (plank, pullups).
//
// Same approach as the push-up harness used to rebuild PushupCounter: a 3D skeleton moves through a timeline, a
// pinhole phone camera (portrait, propped up) projects it to pixels, and the frames get what ML Kit really gives a
// phone — correlated landmark jitter, wandering likelihoods, short single-joint dropouts (with extra jitter), whole-pose
// dropouts and an uneven frame rate. Frames are then fed to the real counters from lib/.
//
// The likelihood tables, jitter size and dropout rates are ASSUMPTIONS calibrated to what ML Kit typically shows,
// not measurements. Passing these tests means the logic is sound under plausible noise; it does not replace testing
// on real phones with real people.
import 'dart:math' as math;

import 'package:fitkey_user/screens/arena/rep_counter.dart';

class V {
  const V(this.x, this.y, this.z);
  final double x, y, z;
  V operator +(V o) => V(x + o.x, y + o.y, z + o.z);
  V operator -(V o) => V(x - o.x, y - o.y, z - o.z);
  V operator *(double k) => V(x * k, y * k, z * k);
  double dot(V o) => x * o.x + y * o.y + z * o.z;
  V cross(V o) => V(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get len => math.sqrt(dot(this));
  V get unit => this * (1 / len);
}

/// World: z up (metres), the camera looks roughly along +y.
typedef Pose3 = Map<Joint, V>;

Pose3 lerpPose(Pose3 a, Pose3 b, double t) => {for (final j in a.keys) j: a[j]! * (1 - t) + b[j]! * t};

/// Smooth 0→1→0 over s in 0..1.
double bump(double s) => (1 - math.cos(2 * math.pi * s)) / 2;

/// Smooth 0→1 over s in 0..1.
double ramp(double s) => (1 - math.cos(math.pi * s.clamp(0.0, 1.0))) / 2;

class Person {
  Person(math.Random r)
      : k = 0.92 + 0.16 * r.nextDouble(),
        arm = 0.94 + 0.12 * r.nextDouble(),
        width = 0.9 + 0.2 * r.nextDouble();
  final double k, arm, width; // overall size, arm proportion, shoulder width proportion
  double get upper => 0.30 * k * arm;
  double get fore => 0.28 * k * arm;
  double get shHalf => 0.19 * k * width;
}

/// Elbow position for shoulder [s], wrist [w], segment lengths [u], [f], bending toward [hint].
V elbowIK(V s, V w, double u, double f, V hint) {
  final d = w - s;
  final c = math.min(d.len, u + f - 1e-6);
  final ch = d.unit;
  final a = (u * u - f * f + c * c) / (2 * c);
  final b = math.sqrt(math.max(0, u * u - a * a));
  final orth = (hint - ch * hint.dot(ch));
  final dir = orth.len < 1e-9 ? const V(0, -1, 0) : orth.unit;
  return s + ch * a + dir * b;
}

// --------------------------------------------------------------------------------------------- plank poses
/// Plank along +x with the head at x = 0. [sag] metres the hips sit below the shoulder–ankle line (negative = pike),
/// [knees] 0 = straight legs, 1 = knees on the floor. [straightArms] = high plank on the hands.
Pose3 plank(Person p, {double sag = 0, double knees = 0, bool straightArms = false, double breathe = 0}) {
  final k = p.k;
  const elbowZ = 0.05, ankZ = 0.08;
  final shZ = (straightArms ? 0.04 + (p.upper + p.fore) * 0.98 : elbowZ + p.upper) + breathe * 0.006;
  final bodyLen = 1.35 * k;
  final ankX = math.sqrt(bodyLen * bodyLen - math.pow(shZ - ankZ, 2));
  double line(double x) => shZ + (ankZ - shZ) * x / ankX;
  final o = <Joint, V>{};
  void side(double sgn, Joint sh, Joint el, Joint wr, Joint hp, Joint kn, Joint an) {
    final hipX = 0.385 * ankX, kneeX = 0.68 * ankX;
    // knees down: shoulder–hip–knee stay in a line, the shins lie on the floor behind the knees
    final kneeDown = V(kneeX, sgn * 0.10 * k, 0.06);
    final hipDown = V(hipX, sgn * 0.10 * k, shZ + (0.06 - shZ) * (hipX / kneeX) - sag);
    final ankDown = V(kneeX + 0.40 * k, sgn * 0.10 * k, 0.10);
    final kneeUp = V(kneeX, sgn * 0.10 * k, line(kneeX) - sag * 0.5);
    final hipUp = V(hipX, sgn * 0.10 * k, line(hipX) - sag);
    final ankUp = V(ankX, sgn * 0.10 * k, ankZ);
    o[sh] = V(0, sgn * p.shHalf, shZ);
    o[hp] = hipUp * (1 - knees) + hipDown * knees;
    o[kn] = kneeUp * (1 - knees) + kneeDown * knees;
    o[an] = ankUp * (1 - knees) + ankDown * knees;
    if (straightArms) {
      o[wr] = V(0, sgn * 0.17 * k, 0.04);
      o[el] = elbowIK(o[sh]!, o[wr]!, p.upper, p.fore, const V(1, 0, 0));
    } else {
      o[el] = V(0, sgn * 0.15 * k, elbowZ);
      o[wr] = V(-0.26 * k, sgn * 0.07 * k, 0.04);
    }
  }

  side(-1, Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist, Joint.leftHip, Joint.leftKnee, Joint.leftAnkle);
  side(1, Joint.rightShoulder, Joint.rightElbow, Joint.rightWrist, Joint.rightHip, Joint.rightKnee, Joint.rightAnkle);
  o[Joint.nose] = V(-0.21 * k, 0, shZ + 0.05);
  return o;
}

/// Lying face down on the floor, forearms forward.
Pose3 lyingProne(Person p) {
  final k = p.k;
  final o = <Joint, V>{};
  void side(double sgn, Joint sh, Joint el, Joint wr, Joint hp, Joint kn, Joint an) {
    o[sh] = V(0, sgn * p.shHalf, 0.12);
    o[el] = V(-0.05, sgn * 0.25 * k, 0.05);
    o[wr] = V(-0.30 * k, sgn * 0.12 * k, 0.04);
    o[hp] = V(0.52 * k, sgn * 0.10 * k, 0.12);
    o[kn] = V(0.92 * k, sgn * 0.10 * k, 0.08);
    o[an] = V(1.33 * k, sgn * 0.10 * k, 0.08);
  }

  side(-1, Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist, Joint.leftHip, Joint.leftKnee, Joint.leftAnkle);
  side(1, Joint.rightShoulder, Joint.rightElbow, Joint.rightWrist, Joint.rightHip, Joint.rightKnee, Joint.rightAnkle);
  o[Joint.nose] = V(-0.2 * k, 0, 0.12);
  return o;
}

/// Kneeling upright (sitting back on the heels is close enough for the counter), facing −x.
Pose3 kneelUp(Person p) {
  final k = p.k;
  final o = <Joint, V>{};
  void side(double sgn, Joint sh, Joint el, Joint wr, Joint hp, Joint kn, Joint an) {
    o[an] = V(0.85 * k, sgn * 0.10 * k, 0.07);
    o[kn] = V(0.45 * k, sgn * 0.10 * k, 0.06);
    o[hp] = V(0.47 * k, sgn * 0.10 * k, 0.52 * k);
    o[sh] = V(0.45 * k, sgn * p.shHalf, 1.02 * k);
    o[el] = V(0.44 * k, sgn * 0.22 * k, 0.74 * k);
    o[wr] = V(0.40 * k, sgn * 0.22 * k, 0.48 * k);
  }

  side(-1, Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist, Joint.leftHip, Joint.leftKnee, Joint.leftAnkle);
  side(1, Joint.rightShoulder, Joint.rightElbow, Joint.rightWrist, Joint.rightHip, Joint.rightKnee, Joint.rightAnkle);
  o[Joint.nose] = V(0.38 * k, 0, 1.2 * k);
  return o;
}

// --------------------------------------------------------------------------------------------- standing / pullups
const barZ = 2.25;

/// Standing at x = 0 facing −y (the camera). [arms] 0 = straight overhead, 1 = "pulled" down beside the head (the
/// end of a lat-pulldown copy). [lift] raises the whole body (calf raise / bounce). [squat] 0..1 bends the knees.
/// [fixedHands] keeps the hands at that world height (holding a low bar) instead of moving with [arms].
Pose3 stand(Person p, {double arms = 0, double lift = 0, double squat = 0, double? fixedHands, double armsDown = 0}) {
  final k = p.k;
  final o = <Joint, V>{};
  final hipZ = 0.95 * k - squat * 0.42 * k + lift;
  final shZ = hipZ + 0.50 * k;
  void side(double sgn, Joint sh, Joint el, Joint wr, Joint hp, Joint kn, Joint an) {
    o[an] = V(sgn * 0.12 * k, 0, 0.08 + lift * 0.8);
    o[kn] = V(sgn * 0.12 * k, -squat * 0.30 * k, 0.50 * k - squat * 0.10 * k + lift * 0.9);
    o[hp] = V(sgn * 0.11 * k, squat * 0.18 * k, hipZ);
    o[sh] = V(sgn * p.shHalf, 0, shZ);
    final up = V(sgn * 0.25 * k, 0, shZ + (p.upper + p.fore) * 0.985);
    final down = V(sgn * 0.30 * k, -0.06, shZ + 0.05);
    final side = V(sgn * 0.20 * k, 0, shZ - (p.upper + p.fore) * 0.98); // arms hanging at the sides
    var w = up * (1 - arms) + down * arms;
    if (armsDown > 0) w = w * (1 - armsDown) + side * armsDown;
    if (fixedHands != null) w = V(sgn * 0.27 * k, 0, fixedHands);
    o[wr] = w;
    o[el] = elbowIK(o[sh]!, w, p.upper, p.fore, V(sgn * 0.9, -0.4, -0.2));
  }

  side(-1, Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist, Joint.leftHip, Joint.leftKnee, Joint.leftAnkle);
  side(1, Joint.rightShoulder, Joint.rightElbow, Joint.rightWrist, Joint.rightHip, Joint.rightKnee, Joint.rightAnkle);
  o[Joint.nose] = V(0, -0.07, shZ + 0.21 * k);
  return o;
}

/// Hanging from the bar at [barZ]. [s] 0 = dead hang, 1 = top (nose [noseOver] m above the bar).
/// [kneeBend] 0 = straight legs, 1 = shins bent back 90°. [sway] sideways swing in metres.
Pose3 hang(Person p, double s, {double kneeBend = 0.4, double sway = 0, double noseOver = 0.12, double gripHalf = 0.27}) {
  final k = p.k;
  final o = <Joint, V>{};
  final hw = gripHalf * k * p.width;
  final reach = (p.upper + p.fore) * 0.985;
  final hangSh = barZ - 0.03 - math.sqrt(reach * reach - math.pow(hw - p.shHalf, 2));
  final topSh = barZ + noseOver - 0.21 * k;
  final shZ = hangSh + (topSh - hangSh) * s;
  final hipZ = shZ - 0.50 * k;
  final kneeZ = hipZ - 0.45 * k;
  final b = kneeBend * math.pi / 2;
  void side(double sgn, Joint sh, Joint el, Joint wr, Joint hp, Joint kn, Joint an) {
    o[wr] = V(sgn * hw, 0, barZ - 0.03);
    o[sh] = V(sgn * p.shHalf + sway, 0.02 * s, shZ);
    o[el] = elbowIK(o[sh]!, o[wr]!, p.upper, p.fore, V(sgn * 0.85, -0.5, -0.1));
    o[hp] = V(sgn * 0.10 * k + sway * 1.3, 0.04, hipZ);
    o[kn] = V(sgn * 0.10 * k + sway * 1.5, -0.02 - 0.1 * kneeBend, kneeZ);
    o[an] = V(sgn * 0.10 * k + sway * 1.6, -0.02 + 0.43 * k * math.sin(b), kneeZ - 0.43 * k * math.cos(b));
  }

  side(-1, Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist, Joint.leftHip, Joint.leftKnee, Joint.leftAnkle);
  side(1, Joint.rightShoulder, Joint.rightElbow, Joint.rightWrist, Joint.rightHip, Joint.rightKnee, Joint.rightAnkle);
  o[Joint.nose] = V(sway, -0.07, shZ + 0.21 * k);
  return o;
}

// --------------------------------------------------------------------------------------------- camera
/// Pinhole camera of a phone standing upright (portrait 480×720 analysed frame).
class Cam {
  Cam({required this.pos, required this.target, this.roll = 0, this.w = 480, this.h = 720, this.hfov = 55});
  final V pos, target;
  final double roll, hfov;
  final int w, h;
  late final V _fwd = (target - pos).unit;
  late final V _right = _fwd.cross(const V(0, 0, 1)).unit;
  late final V _up = _right.cross(_fwd).unit;
  late final double _f = (w / 2) / math.tan(hfov * math.pi / 360);

  /// Pixel position, or null behind the camera.
  List<double>? project(V p) {
    final d = p - pos;
    final z = d.dot(_fwd);
    if (z < 0.2) return null;
    final x = _f * d.dot(_right) / z, y = -_f * d.dot(_up) / z;
    final r = roll * math.pi / 180;
    return [w / 2 + x * math.cos(r) - y * math.sin(r), h / 2 + x * math.sin(r) + y * math.cos(r)];
  }

  /// Side-on to a plank lying along +x from x = 0 (camera on the −y side). [az] turns the camera toward the feet.
  factory Cam.plankSide({double dist = 2.75, double height = 0.25, double az = 0, double roll = 1.5, double mid = 0.65}) {
    final a = az * math.pi / 180;
    return Cam(pos: V(mid + dist * math.sin(a), -dist * math.cos(a), height), target: V(mid, 0, 0.2), roll: roll);
  }

  /// In front of a pullup bar / standing person at the origin.
  factory Cam.front({double dist = 2.6, double height = 1.0, double az = 0, double roll = 1.0, double lookAt = 1.45}) {
    final a = az * math.pi / 180;
    return Cam(pos: V(dist * math.sin(a), -dist * math.cos(a), height), target: V(0, 0, lookAt), roll: roll, hfov: 52);
  }
}

// --------------------------------------------------------------------------------------------- noise
enum View { side, front }

/// Assumed ML Kit in-frame likelihoods. Side view: joints on the far side of the body are often guessed.
const _sideNear = {
  Joint.nose: 0.97, Joint.leftShoulder: 0.98, Joint.leftElbow: 0.9, Joint.leftWrist: 0.78, Joint.leftHip: 0.92,
  Joint.leftKnee: 0.85, Joint.leftAnkle: 0.72, //
};
const _sideFar = {
  Joint.rightShoulder: 0.85, Joint.rightElbow: 0.45, Joint.rightWrist: 0.35, Joint.rightHip: 0.70,
  Joint.rightKnee: 0.45, Joint.rightAnkle: 0.35, //
};
const _frontUpright = {
  Joint.nose: 0.97, Joint.leftShoulder: 0.97, Joint.rightShoulder: 0.97, Joint.leftElbow: 0.9, Joint.rightElbow: 0.9,
  Joint.leftWrist: 0.84, Joint.rightWrist: 0.84, Joint.leftHip: 0.9, Joint.rightHip: 0.9, Joint.leftKnee: 0.85,
  Joint.rightKnee: 0.85, Joint.leftAnkle: 0.78, Joint.rightAnkle: 0.78, //
};

class Noise {
  const Noise({
    this.px = 3.0,
    this.lik = 0.09,
    this.jointDropPer10s = 1.0,
    this.poseDropEvery = 0,
    this.poseDropLen = 0.8,
    this.clean = false,
  });

  /// Landmark jitter (pixels, AR(1) with an 80 ms correlation time).
  final double px;

  /// Likelihood wander (std).
  final double lik;

  /// Single-joint dropouts per joint per 10 s (likelihood falls to 0.1–0.4 and jitter grows 2.5×).
  final double jointDropPer10s;

  /// Whole-pose dropouts (no person returned) every ~N s, lasting ~[poseDropLen] s. 0 = never.
  final double poseDropEvery, poseDropLen;
  final bool clean;
}

class Seg {
  Seg(this.dur, this.fn);
  final double dur;
  final Pose3 Function(double s) fn; // s in 0..1 across the segment
}

class SimFrame {
  SimFrame(this.t, this.pose);
  final Duration t;
  final PoseFrame? pose;
}

/// Renders a timeline into the frames the camera screen would feed a counter.
List<SimFrame> render(List<Seg> segs, Cam cam, View view, math.Random r,
    {Noise noise = const Noise(), double fps = 12, double nearSideY = -1}) {
  final total = segs.fold<double>(0, (a, s) => a + s.dur);
  final ar = <Joint, List<double>>{for (final j in Joint.values) j: [0, 0, 0]};
  final dropUntil = <Joint, double>{};
  double gauss() => math.sqrt(-2 * math.log(1 - r.nextDouble())) * math.cos(2 * math.pi * r.nextDouble());
  final out = <SimFrame>[];
  var t = 0.0;
  var nextPoseDrop = noise.poseDropEvery > 0 ? noise.poseDropEvery * (0.6 + 0.8 * r.nextDouble()) : double.infinity;
  var poseDropEnd = -1.0;
  while (true) {
    final dt = (1 / fps) * (0.8 + 0.4 * r.nextDouble());
    t += dt;
    if (t >= total) break;
    final stamp = Duration(microseconds: (t * 1e6).round());
    if (t >= nextPoseDrop) {
      poseDropEnd = t + noise.poseDropLen * (0.7 + 0.6 * r.nextDouble());
      nextPoseDrop = poseDropEnd + noise.poseDropEvery * (0.6 + 0.8 * r.nextDouble());
    }
    if (t < poseDropEnd) {
      out.add(SimFrame(stamp, null));
      continue;
    }
    var acc = 0.0;
    late Pose3 pose;
    for (final s in segs) {
      if (t < acc + s.dur) {
        pose = s.fn((t - acc) / s.dur);
        break;
      }
      acc += s.dur;
    }
    final pts = <Joint, Pt>{};
    final rho = math.exp(-dt / 0.08);
    final innov = math.sqrt(1 - rho * rho);
    for (final j in Joint.values) {
      final pp = cam.project(pose[j]!);
      if (pp == null) continue;
      final a = ar[j]!;
      final sig = noise.clean ? 0.0 : noise.px;
      a[0] = rho * a[0] + innov * gauss() * sig;
      a[1] = rho * a[1] + innov * gauss() * sig;
      a[2] = rho * a[2] + innov * gauss() * (noise.clean ? 0 : noise.lik);
      double base;
      if (view == View.front) {
        base = _frontUpright[j]!;
      } else {
        // which body side faces the camera: the side whose y has the sign of [nearSideY]
        final near = j == Joint.nose || (pose[j]!.y * nearSideY) >= 0;
        final name = j.name.replaceFirst(RegExp('^(left|right)'), '');
        final key = Joint.values.byName(j == Joint.nose ? 'nose' : '${near ? 'left' : 'right'}$name');
        base = near ? _sideNear[key]! : _sideFar[key]!;
      }
      var l = noise.clean ? 0.95 : (base + a[2]).clamp(0.0, 1.0);
      var extra = 1.0;
      if (!noise.clean && j != Joint.nose && j != Joint.leftShoulder && j != Joint.rightShoulder) {
        if (r.nextDouble() < noise.jointDropPer10s * dt / 10) dropUntil[j] = t + 0.3 + 0.7 * r.nextDouble();
        if ((dropUntil[j] ?? 0) > t) {
          l = math.min(l, 0.1 + 0.3 * r.nextDouble());
          extra = 2.5;
        }
      }
      final x = pp[0] + a[0] * extra, y = pp[1] + a[1] * extra;
      if (x < 0 || y < 0 || x >= cam.w || y >= cam.h) l = math.min(l, 0.05);
      pts[j] = Pt(x, y, l);
    }
    out.add(SimFrame(stamp, pts));
  }
  return out;
}

/// Feeds [frames] to a fresh counter for [exerciseId]. [onFrame] sees the counter after every frame.
RepCounter runCounter(String exerciseId, List<SimFrame> frames, {void Function(SimFrame f, RepCounter c)? onFrame}) {
  final c = RepCounter.forExercise(exerciseId);
  for (final f in frames) {
    c.update(f.pose, f.t);
    onFrame?.call(f, c);
  }
  return c;
}

/// Seconds of a timeline before segment [index].
double startOf(List<Seg> segs, int index) => segs.take(index).fold<double>(0, (a, s) => a + s.dur);
