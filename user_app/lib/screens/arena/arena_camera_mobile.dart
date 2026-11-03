import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings, Permission, PermissionCheckShortcuts;
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/arena_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'arena_visuals.dart';
import 'pose_painter.dart';
import 'rep_counter.dart';

/// Clips above this are not uploaded (server limit for videos is 12 MB).
const _maxClipBytes = 12 * 1024 * 1024;

/// Recording restarts every [_segment] so the proof clip stays short (the newest segment is kept).
const _segment = Duration(seconds: 45);

/// startVideoRecording(onAvailable:) rotates the preview on this camera plugin (flutter/flutter#180075) and
/// frame delivery while recording is unreliable across phones. Counting reliability comes first: clips are off.
const _recordProofClip = false;

/// On-screen pipeline readout (frames, poses, rotation, errors), so one screenshot from a real phone shows which
/// stage fails. Turn off before the public release.
const _showDiagnostics = true;

/// Above this average per-frame cost the accurate pose model is replaced by the faster base model.
const _maxAccurateMs = 350;

enum _Phase { loading, error, ready, countdown, active, review, saving, done }

/// Live AI rep counter: front camera → ML Kit pose → [RepCounter]. Pops `true` when a set was saved.
class ArenaCameraScreen extends StatefulWidget {
  const ArenaCameraScreen({super.key, required this.exercise, this.level});

  final ArenaExercise exercise;
  final ArenaLevel? level;

  @override
  State<ArenaCameraScreen> createState() => _ArenaCameraScreenState();
}

class _ArenaCameraScreenState extends State<ArenaCameraScreen> with WidgetsBindingObserver {
  CameraController? _c;
  // Accurate first: Google's advice for bodies on the floor. Swapped for base if the phone is too slow.
  PoseDetector _detector = PoseDetector(
    options: PoseDetectorOptions(mode: PoseDetectionMode.stream, model: PoseDetectionModel.accurate),
  );
  bool _accurateModel = true;
  int _latencyMs = 0, _latencyN = 0;

  bool _initializing = false;
  Future<void>? _releasing;

  // Diagnostics + watchdog
  Timer? _watchdog;
  DateTime? _lastFrameAt;
  int _dFrames = 0, _dFramesPrev = 0, _dFps = 0, _dPoses = 0, _dEmpty = 0, _dErrors = 0;
  String _dLastError = '';
  int _dRotation = -1;

  _Phase _phase = _Phase.loading;
  String? _error;
  bool _permissionDenied = false;

  late RepCounter _counter = RepCounter.forExercise(widget.exercise.id);
  PoseFrame? _pose;
  Size _imageSize = Size.zero;
  bool _busy = false;
  bool _streaming = false;

  // Recording (proof clip)
  bool _recording = false;
  DateTime? _segmentStart;
  XFile? _prevSegment;
  Timer? _segmentTimer;
  XFile? _clip;

  // Timing
  final _active = Stopwatch();
  Timer? _ticker;
  Timer? _countdownTimer;
  int _countdown = 3;

  bool _levelDone = false;
  bool _showLevelBanner = false;
  bool _saved = false;
  ArenaSubmitResult? _result;
  String? _clipNote;
  bool _clipFailed = false;

  int? get _target => widget.level?.target;

  /// Where to put the phone: always upright (portrait); a flat phone's front camera only sees the ceiling.
  String get _placementHint => switch (widget.exercise.id) {
    'pushups' =>
      'Stand the phone upright against a wall or bottle, at floor level, about 2 m away — in front of you or to your side. Keep your head, shoulders and arms in view.',
    'plank' || 'burpees' =>
      'Stand the phone upright against a wall or bottle, 2.5–3 m away and side-on to you, with head to feet in view.',
    'squats' =>
      'Stand the phone upright at hip height, 2–3 m away and side-on or at an angle, with head to feet in view.',
    _ => 'Stand the phone upright 2–3 m away, so the bar and your whole body are in view.',
  };

  @override
  void initState() {
    super.initState();
    // Portrait for every exercise: the screen never rotates and the image rotation sent to ML Kit is constant,
    // instead of depending on a sensor-driven value that can be stale (which made bodies look vertical → no reps).
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    WidgetsBinding.instance.addObserver(this);
    // Keep the screen awake during long sets (e.g. a 2-minute plank).
    WakelockPlus.enable().catchError((_) {});
    _init();
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _checkFrames());
  }

  /// Once a second: updates the fps readout and restarts the stream if frames stopped arriving.
  void _checkFrames() {
    if (!mounted) return;
    _dFps = _dFrames - _dFramesPrev;
    _dFramesPrev = _dFrames;
    final live = _phase == _Phase.ready || _phase == _Phase.countdown || _phase == _Phase.active;
    final last = _lastFrameAt;
    if (live && _streaming && last != null && DateTime.now().difference(last) > const Duration(seconds: 3)) {
      _lastFrameAt = DateTime.now();
      _dLastError = 'no frames for 3s, restarting camera stream';
      _stopPreviewStream().then((_) => _startPreviewStream()).catchError((Object e) {
        _dErrors++;
        _dLastError = '$e';
      });
    }
    if (_showDiagnostics) setState(() {});
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const []);
    WakelockPlus.disable().catchError((_) {});
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _watchdog?.cancel();
    _countdownTimer?.cancel();
    _segmentTimer?.cancel();
    final c = _c;
    _c = null;
    c?.dispose().catchError((_) {});
    _detector.close();
    _deleteFile(_prevSegment);
    _deleteFile(_clip);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only "paused" means we left the app. "inactive" also fires for the notification shade and system overlays,
    // and must not end a set or drop the camera.
    if (state == AppLifecycleState.paused) {
      if (_phase == _Phase.active) {
        _finish();
      } else if (_phase == _Phase.ready || _phase == _Phase.countdown) {
        _countdownTimer?.cancel();
        _releaseCamera();
        setState(() => _phase = _Phase.loading);
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_phase == _Phase.loading && _c == null) {
        _init();
      } else if (_phase == _Phase.error && _permissionDenied) {
        // Back from Settings: retry only if access was really granted, or this would re-prompt in a loop.
        Permission.camera.isGranted.then((ok) {
          if (ok && mounted) _init();
        });
      }
    }
  }

  // ---------------------------------------------------------------------------------------------- camera

  Future<void> _init() async {
    // The permission dialog triggers "resumed" while initialize() is still running: never start the camera twice.
    if (_initializing) return;
    _initializing = true;
    setState(() {
      _phase = _Phase.loading;
      _error = null;
      _permissionDenied = false;
    });
    CameraController? pending;
    try {
      // A late dispose of the previous camera would unbind the new one.
      await _releasing;
      final cams = await availableCameras();
      if (cams.isEmpty) throw CameraException('NoCamera', 'No camera found on this device');
      final cam = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first);
      final c = pending = CameraController(
        cam,
        ResolutionPreset.high, // same as Google's sample: a body on the floor needs the pixels (256 px guidance)
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      try {
        await c.lockCaptureOrientation(DeviceOrientation.portraitUp); // also keeps CameraPreview's layout portrait
      } catch (_) {}
      _c = c;
      _lastFrameAt = DateTime.now();
      await _startPreviewStream();
      pending = null;
      if (!mounted) return;
      setState(() => _phase = _Phase.ready);
    } on CameraException catch (e) {
      _dropFailed(pending);
      if (!mounted) return;
      final denied = e.code.contains('AccessDenied') || e.code.contains('Restricted') || e.code == 'cameraPermission';
      setState(() {
        _phase = _Phase.error;
        _permissionDenied = denied;
        _error = denied
            ? 'FITKEY needs camera access to count your reps. No video is recorded or uploaded.'
            : (e.description ?? 'The camera could not be started.');
      });
    } catch (e) {
      _dropFailed(pending);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = 'The camera could not be started.';
        _dLastError = '$e';
      });
    } finally {
      _initializing = false;
    }
  }

  /// Frees a controller whose start-up failed, so it can't block the next attempt.
  void _dropFailed(CameraController? c) {
    if (c == null) return;
    if (identical(_c, c)) _c = null;
    _streaming = false;
    _releasing = c.dispose().catchError((_) {});
  }

  Future<void> _releaseCamera() {
    final c = _c;
    _c = null;
    _streaming = false;
    _recording = false;
    _segmentTimer?.cancel();
    return _releasing = c?.dispose().catchError((_) {}) ?? Future<void>.value();
  }

  Future<void> _startPreviewStream() async {
    final c = _c;
    if (c == null || _streaming) return;
    await c.startImageStream(_onFrame);
    _streaming = true;
  }

  Future<void> _stopPreviewStream() async {
    final c = _c;
    if (c == null || !_streaming) return;
    _streaming = false;
    try {
      await c.stopImageStream();
    } catch (_) {}
  }

  /// Starts video recording while still receiving frames for ML Kit. Falls back to stream-only.
  Future<void> _startRecording() async {
    final c = _c;
    if (c == null) return;
    await _stopPreviewStream();
    try {
      await c.startVideoRecording(onAvailable: _onFrame);
      _recording = true;
      _segmentStart = DateTime.now();
      _segmentTimer?.cancel();
      _segmentTimer = Timer.periodic(_segment, (_) => _rotateSegment());
    } catch (e) {
      debugPrint('Arena: video recording unavailable ($e) — counting without a clip');
      _recording = false;
      await _startPreviewStream();
    }
  }

  /// Keeps only the newest ~45 s: closes the current segment and starts a new one.
  Future<void> _rotateSegment() async {
    final c = _c;
    if (c == null || !_recording || _phase != _Phase.active) return;
    try {
      final file = await c.stopVideoRecording();
      _deleteFile(_prevSegment);
      _prevSegment = file;
      await c.startVideoRecording(onAvailable: _onFrame);
      _segmentStart = DateTime.now();
    } catch (e) {
      debugPrint('Arena: segment rotation failed ($e)');
      _recording = false;
      _segmentTimer?.cancel();
      try {
        await _startPreviewStream();
      } catch (_) {}
    }
  }

  /// Stops camera output and picks the proof clip: the last segment, or the previous full one if the last is tiny.
  Future<void> _stopCamera() async {
    _segmentTimer?.cancel();
    final c = _c;
    if (c == null) return;
    if (_recording) {
      _recording = false;
      try {
        final last = await c.stopVideoRecording();
        final lastLen = DateTime.now().difference(_segmentStart ?? DateTime.now());
        if (lastLen >= const Duration(seconds: 12) || _prevSegment == null) {
          _deleteFile(_prevSegment);
          _clip = last;
        } else {
          _deleteFile(last);
          _clip = _prevSegment;
        }
        _prevSegment = null;
      } catch (e) {
        debugPrint('Arena: stopping the recording failed ($e)');
      }
    } else {
      await _stopPreviewStream();
    }
  }

  void _deleteFile(XFile? f) {
    if (f == null) return;
    File(f.path).delete().catchError((_) => File(f.path));
  }

  // ---------------------------------------------------------------------------------------------- ML Kit

  InputImage? _toInputImage(CameraImage image) {
    final c = _c;
    if (c == null) return null;
    final cam = c.description;

    // The screen is locked to portraitUp, so the display contributes 0° and the rotation is just the sensor's.
    final rotation = InputImageRotationValue.fromRawValue(cam.sensorOrientation);
    if (rotation == null) return null;
    _dRotation = cam.sensorOrientation;

    final w = image.width, h = image.height;
    final sideways = rotation == InputImageRotation.rotation90deg || rotation == InputImageRotation.rotation270deg;
    // ML Kit returns landmarks in the upright (rotated) frame on Android; iOS buffers arrive upright already.
    _imageSize = Platform.isAndroid && sideways ? Size(h.toDouble(), w.toDouble()) : Size(w.toDouble(), h.toDouble());
    final size = Size(w.toDouble(), h.toDouble());

    if (Platform.isAndroid) {
      final Uint8List bytes;
      if (image.planes.length == 1) {
        bytes = image.planes.first.bytes; // NV21, already packed by CameraX
      } else if (image.planes.length == 3) {
        bytes = _yuv420ToNv21(image); // devices that only deliver YUV_420_888
      } else {
        return null;
      }
      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(size: size, rotation: rotation, format: InputImageFormat.nv21, bytesPerRow: w),
      );
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw as int);
    if (format != InputImageFormat.bgra8888 || image.planes.length != 1) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(size: size, rotation: rotation, format: format!, bytesPerRow: plane.bytesPerRow),
    );
  }

  /// Packs a 3-plane YUV_420_888 image (with row / pixel strides) into NV21 (Y plane + interleaved VU).
  static Uint8List _yuv420ToNv21(CameraImage img) {
    final w = img.width, h = img.height;
    final yP = img.planes[0], uP = img.planes[1], vP = img.planes[2];
    final out = Uint8List(w * h + 2 * (w ~/ 2) * (h ~/ 2));
    var i = 0;
    for (var row = 0; row < h; row++) {
      out.setRange(i, i + w, yP.bytes, row * yP.bytesPerRow);
      i += w;
    }
    final uStep = uP.bytesPerPixel ?? 1, vStep = vP.bytesPerPixel ?? 1;
    for (var row = 0; row < h ~/ 2; row++) {
      final uRow = row * uP.bytesPerRow, vRow = row * vP.bytesPerRow;
      for (var col = 0; col < w ~/ 2; col++) {
        out[i++] = vP.bytes[vRow + col * vStep];
        out[i++] = uP.bytes[uRow + col * uStep];
      }
    }
    return out;
  }

  static PoseFrame _toFrame(Pose pose) {
    final out = <Joint, Pt>{};
    for (final j in Joint.values) {
      final lm = pose.landmarks[PoseLandmarkType.values.byName(j.name)];
      if (lm != null) out[j] = Pt(lm.x, lm.y, lm.likelihood);
    }
    return out;
  }

  void _onFrame(CameraImage image) {
    _dFrames++;
    _lastFrameAt = DateTime.now();
    if (_busy || !mounted) return;
    final input = _toInputImage(image);
    if (input == null) {
      _dLastError = 'unsupported frame: planes=${image.planes.length} format=${image.format.raw}';
      return;
    }
    _busy = true;
    final sw = Stopwatch()..start();
    // The timeout keeps one stuck detection from silently stopping the counter for good.
    _detector
        .processImage(input)
        .timeout(const Duration(seconds: 5))
        .then((poses) {
          if (!mounted) return;
          _noteLatency(sw.elapsedMilliseconds);
          poses.isEmpty ? _dEmpty++ : _dPoses++;
          final frame = poses.isEmpty ? null : _toFrame(poses.first);
          if (_phase == _Phase.active) {
            final before = _counter.reps;
            _counter.update(frame, _active.elapsed);
            if (_counter.reps > before) _onRep();
          }
          setState(() => _pose = frame);
        })
        .catchError((Object e) {
          debugPrint('Arena: pose detection failed ($e)');
          _dErrors++;
          _dLastError = '$e';
        })
        .whenComplete(() => _busy = false);
  }

  /// Drops to the base model when the accurate one is too slow on this phone (first frames load the model, skip them).
  void _noteLatency(int ms) {
    if (!_accurateModel) return;
    _latencyN++;
    if (_latencyN <= 3) return;
    _latencyMs += ms;
    if (_latencyN >= 18 && _latencyMs / (_latencyN - 3) > _maxAccurateMs) {
      _accurateModel = false;
      final old = _detector;
      _detector = PoseDetector(
        options: PoseDetectorOptions(mode: PoseDetectionMode.stream, model: PoseDetectionModel.base),
      );
      old.close().catchError((_) {});
    }
  }

  Widget _diagnostics() {
    final c = _c;
    final seen = _pose == null ? 0 : _pose!.values.where((p) => p.likelihood >= kMinLikelihood).length;
    final lines = [
      'cam ${_dFps}fps frames=$_dFrames  ai pose=$_dPoses none=$_dEmpty err=$_dErrors',
      'rot=$_dRotation sensor=${c?.description.sensorOrientation} ${_imageSize.width.toInt()}x${_imageSize.height.toInt()} '
          '${_accurateModel ? "accurate" : "base"} points=$seen/33',
      if (_phase == _Phase.active)
        'reps=${_counter.reps} partial=${_counter.partialReps} tracking=${_counter.tracking}',
      if (_dLastError.isNotEmpty) _dLastError,
    ];
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
        child: Text(
          lines.join('\n'),
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 10.5, height: 1.3, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  void _onRep() {
    if (widget.exercise.timed) {
      HapticFeedback.selectionClick();
    } else {
      HapticFeedback.mediumImpact();
      SystemSound.play(SystemSoundType.click);
    }
    final t = _target;
    if (t != null && !_levelDone && _counter.reps >= t) {
      _levelDone = true;
      _showLevelBanner = true;
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _showLevelBanner = false);
      });
    }
  }

  // ---------------------------------------------------------------------------------------------- flow

  Future<void> _startCountdown() async {
    setState(() {
      _phase = _Phase.countdown;
      _countdown = 3;
    });
    HapticFeedback.selectionClick();
    // Switch to recording now so the brief stream hand-over happens during the countdown, not mid-set.
    if (_recordProofClip) await _startRecording();
    if (!mounted || _phase != _Phase.countdown) return;
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      if (_countdown <= 1) {
        t.cancel();
        _begin();
      } else {
        HapticFeedback.selectionClick();
        setState(() => _countdown--);
      }
    });
  }

  void _begin() {
    HapticFeedback.heavyImpact();
    _counter = RepCounter.forExercise(widget.exercise.id);
    _active
      ..reset()
      ..start();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
    setState(() => _phase = _Phase.active);
  }

  Future<void> _finish() async {
    if (_phase != _Phase.active) return;
    _active.stop();
    _ticker?.cancel();
    setState(() => _phase = _Phase.review);
    await _stopCamera();
    if (mounted) setState(() {});
  }

  Future<void> _again() async {
    _deleteFile(_clip);
    _clip = null;
    _counter = RepCounter.forExercise(widget.exercise.id);
    _levelDone = false;
    _showLevelBanner = false;
    _result = null;
    _clipNote = null;
    _clipFailed = false;
    _active.reset();
    if (_c == null) return _init();
    try {
      await _startPreviewStream();
    } catch (_) {
      await _releaseCamera();
      return _init();
    }
    if (mounted) setState(() => _phase = _Phase.ready);
  }

  Future<void> _save() async {
    final api = context.read<Session>().api;
    setState(() => _phase = _Phase.saving);
    try {
      final r = await api.submitArenaAttempt(
        exerciseId: widget.exercise.id,
        level: _target,
        reps: _counter.reps,
        durationSec: math.max(1, _active.elapsed.inSeconds),
        partialReps: _counter.partialReps,
      );
      _saved = true;
      _result = r;
      if (r.clipRequired) {
        if (mounted) setState(() => _clipNote = 'Uploading your proof clip…');
        await _uploadClip();
      } else {
        _deleteFile(_clip);
        _clip = null;
      }
      if (!mounted) return;
      setState(() => _phase = _Phase.done);
    } catch (e) {
      if (!mounted) return;
      toast(context, friendlyError(e), error: true);
      setState(() => _phase = _Phase.review);
    }
  }

  Future<void> _uploadClip() async {
    final api = context.read<Session>().api;
    final r = _result!;
    final clip = _clip;
    try {
      if (clip == null) {
        await api.attachArenaClip(r.attempt.id, null);
        _clipNote = _recordProofClip
            ? 'This phone could not record a proof clip — your set is saved without one.'
            : 'Your set is saved and on the leaderboard.';
        return;
      }
      var file = File(clip.path);
      if (await file.length() > _maxClipBytes) {
        await api.attachArenaClip(r.attempt.id, null);
        _clipNote = 'The proof clip was too large to upload — your set is saved without one.';
        return;
      }
      // The upload API detects video by the .mp4 extension.
      if (!file.path.toLowerCase().endsWith('.mp4')) file = await file.copy('${file.path}.mp4');
      final url = await api.upload(XFile(file.path));
      await api.attachArenaClip(r.attempt.id, url);
      if (file.path != clip.path) file.delete().catchError((_) => file);
      _deleteFile(clip);
      _clip = null;
      _clipNote = 'Proof clip uploaded — it is shown next to your top-10 entry.';
      _clipFailed = false;
    } catch (e) {
      _clipFailed = clip != null;
      _clipNote = 'Proof clip upload failed: ${friendlyError(e)}';
    }
  }

  Future<void> _retryClip() async {
    setState(() => _clipNote = 'Uploading your proof clip…');
    await _uploadClip();
    if (mounted) setState(() {});
  }

  Future<bool> _confirmLeave() async {
    if (_phase != _Phase.active && _phase != _Phase.review) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this set?'),
        content: Text(
          _counter.reps > 0
              ? 'Your ${widget.exercise.format(_counter.reps)} will not be saved to the leaderboard.'
              : 'Nothing has been counted yet.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep going')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
        ],
      ),
    );
    return leave == true;
  }

  Future<void> _close() async {
    if (_phase == _Phase.saving) return;
    if (!await _confirmLeave()) return;
    if (mounted) Navigator.pop(context, _saved);
  }

  // ---------------------------------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    if (_phase == _Phase.error) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(title: Text(widget.exercise.name)),
        body: EmptyView(
          icon: _permissionDenied ? Icons.no_photography_rounded : Icons.videocam_off_rounded,
          title: _permissionDenied ? 'Camera access needed' : 'Camera unavailable',
          message: _error,
          action: SizedBox(
            width: 200,
            child: AppButton(
              label: _permissionDenied ? 'Open settings' : 'Try again',
              icon: _permissionDenied ? Icons.settings_rounded : Icons.refresh_rounded,
              onPressed: _permissionDenied ? () => openAppSettings() : _init,
            ),
          ),
        ),
      );
    }

    final v = arenaVisual(widget.exercise.id);
    final c = _c;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (c != null && c.value.isInitialized && _phase != _Phase.done && _phase != _Phase.saving)
              Center(
                child: CameraPreview(
                  c,
                  child: CustomPaint(
                    painter: PosePainter(
                      pose: _pose,
                      imageSize: _imageSize,
                      mirror: c.description.lensDirection == CameraLensDirection.front,
                      color: _phase == _Phase.active && _counter.tracking ? AppColors.lime : v.color,
                    ),
                  ),
                ),
              )
            else if (_phase == _Phase.loading)
              const Center(child: CircularProgressIndicator(color: Colors.white)),
            SafeArea(child: _topBar(v)),
            if (_showDiagnostics)
              Positioned(
                top: MediaQuery.paddingOf(context).top + (_phase == _Phase.active ? 180 : 62),
                left: 0,
                right: 0,
                child: Align(alignment: Alignment.topLeft, child: _diagnostics()),
              ),
            if (_phase == _Phase.active) ..._activeOverlay(v),
            if (_phase == _Phase.countdown) _countdownOverlay(),
            if (_phase == _Phase.ready) Align(alignment: Alignment.bottomCenter, child: _readyPanel(v)),
            if (_phase == _Phase.review || _phase == _Phase.saving)
              Align(alignment: Alignment.bottomCenter, child: _reviewPanel(v)),
            if (_phase == _Phase.done) Align(alignment: Alignment.bottomCenter, child: _donePanel(v)),
          ],
        ),
      ),
    );
  }

  Widget _circleButton(IconData icon, VoidCallback onTap) => Tap(
    onTap: onTap,
    child: Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
      child: Icon(icon, color: Colors.white, size: 22),
    ),
  );

  Widget _pill(Widget child, {Color? color}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: color ?? Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );

  Widget _topBar(ArenaVisual v) {
    final level = widget.level;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          _circleButton(Icons.close_rounded, _close),
          const SizedBox(width: 10),
          Flexible(
            child: _pill(
              Text(
                level == null
                    ? widget.exercise.name
                    : '${widget.exercise.name} · ${widget.exercise.format(level.target)}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
              ),
            ),
          ),
          const Spacer(),
          if (_phase == _Phase.active) ...[
            if (_recording)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _pill(
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.fiber_manual_record_rounded, color: AppColors.red, size: 12),
                      SizedBox(width: 4),
                      Text(
                        'REC',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            _pill(
              Text(
                _clock(_active.elapsed),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _clock(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  List<Widget> _activeOverlay(ArenaVisual v) {
    final cue = _counter.cue;
    final cueColor = switch (cue.tone) {
      CueTone.good => AppColors.green,
      CueTone.warn => AppColors.amber,
      CueTone.info => AppColors.ink,
    };
    final t = _target;
    final progress = t == null ? null : (_counter.reps / t).clamp(0.0, 1.0);
    return [
      // Form cue banner
      Positioned(
        top: MediaQuery.paddingOf(context).top + 62,
        left: 16,
        right: 16,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Container(
            key: ValueKey(cue.text),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: cueColor.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                Icon(
                  switch (cue.tone) {
                    CueTone.good => Icons.check_circle_rounded,
                    CueTone.warn => Icons.warning_amber_rounded,
                    CueTone.info => Icons.info_outline_rounded,
                  },
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    cue.text,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      if (_showLevelBanner)
        Positioned(
          top: MediaQuery.paddingOf(context).top + 124,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: AppColors.primaryGradient,
              borderRadius: BorderRadius.circular(16),
              boxShadow: AppShadows.glow(AppColors.primary),
            ),
            child: Row(
              children: [
                const Icon(Icons.emoji_events_rounded, color: Colors.white, size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Level complete — ${widget.exercise.format(t!)}!',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                      const Text(
                        'Keep going for a bigger set, or tap Finish.',
                        style: TextStyle(color: Colors.white, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      // Big counter + finish
      Positioned(
        left: 16,
        right: 16,
        bottom: MediaQuery.paddingOf(context).bottom + 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 168,
              height: 168,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
                  ),
                  if (progress != null)
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 8,
                        color: _levelDone ? AppColors.lime : v.color,
                        backgroundColor: Colors.white.withValues(alpha: 0.18),
                      ),
                    ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TweenAnimationBuilder<double>(
                        key: ValueKey(_counter.reps),
                        tween: Tween(begin: 1.25, end: 1),
                        duration: const Duration(milliseconds: 250),
                        builder: (_, s, child) => Transform.scale(scale: s, child: child),
                        child: Text(
                          '${_counter.reps}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 64,
                            fontWeight: FontWeight.w800,
                            height: 1,
                            letterSpacing: -2,
                          ),
                        ),
                      ),
                      Text(
                        t == null ? (widget.exercise.timed ? 'seconds' : 'reps') : '/ ${widget.exercise.format(t)}',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_counter.partialReps > 0) ...[
              const SizedBox(height: 8),
              _pill(
                Text(
                  widget.exercise.timed
                      ? '${_counter.partialReps} form ${_counter.partialReps == 1 ? 'break' : 'breaks'}'
                      : '${_counter.partialReps} partial ${_counter.partialReps == 1 ? 'rep' : 'reps'} not counted',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 14),
            AppButton(
              label: _levelDone ? 'Finish & save' : 'Finish',
              icon: Icons.flag_rounded,
              color: _levelDone ? AppColors.green : AppColors.surface,
              foreground: _levelDone ? Colors.white : AppColors.ink,
              onPressed: _finish,
            ),
          ],
        ),
      ),
    ];
  }

  Widget _countdownOverlay() => Container(
    color: Colors.black.withValues(alpha: 0.35),
    alignment: Alignment.center,
    child: TweenAnimationBuilder<double>(
      key: ValueKey(_countdown),
      tween: Tween(begin: 1.6, end: 1),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutBack,
      builder: (_, s, child) => Transform.scale(scale: s, child: child),
      child: Text(
        '$_countdown',
        style: const TextStyle(color: Colors.white, fontSize: 140, fontWeight: FontWeight.w800, height: 1),
      ),
    ),
  );

  // Narrow and scrollable so it fits the short landscape screen without hiding the person.
  Widget _sheet({required Widget child}) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.sizeOf(context).height * 0.85),
    child: Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(20, 18, 20, 16 + MediaQuery.paddingOf(context).bottom),
      child: SingleChildScrollView(child: child),
    ),
  );

  Widget _readyPanel(ArenaVisual v) {
    final seen = _pose != null && _pose!.values.where((p) => p.likelihood >= kMinLikelihood).length >= 8;
    return _sheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBubble(
                seen ? Icons.check_rounded : Icons.person_search_rounded,
                color: seen ? AppColors.green : v.color,
                bg: seen ? AppColors.greenSoft : v.soft,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      seen ? 'We can see you — ready when you are' : 'Get your whole body in the frame',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                    const SizedBox(height: 2),
                    Text(_placementHint, style: const TextStyle(color: AppColors.text2, fontSize: 13, height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: 15, color: AppColors.text3),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Reps are counted on your phone — no video is recorded or uploaded.',
                  style: TextStyle(color: AppColors.text3, fontSize: 11.5, height: 1.35),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AppButton(label: 'Start · 3-2-1', icon: Icons.play_arrow_rounded, onPressed: _startCountdown),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
    child: Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );

  Widget _reviewPanel(ArenaVisual v) {
    final ex = widget.exercise;
    final reps = _counter.reps;
    final t = _target;
    final done = t != null && reps >= t;
    final saving = _phase == _Phase.saving;
    return _sheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconBubble(
            done ? Icons.emoji_events_rounded : Icons.flag_rounded,
            color: done ? AppColors.amber : v.color,
            bg: done ? AppColors.amberSoft : v.soft,
            size: 56,
          ),
          const SizedBox(height: 10),
          Text(
            reps == 0
                ? 'No ${ex.timed ? 'hold time' : 'reps'} counted'
                : done
                ? 'Level complete!'
                : t == null
                ? 'Set finished'
                : '${ex.format(t - reps)} short of the level',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _stat(ex.timed ? 'held' : 'reps', ex.timed ? '${reps}s' : '$reps'),
              _stat('time', _clock(_active.elapsed)),
              _stat(ex.timed ? 'form breaks' : 'not counted', '${_counter.partialReps}'),
            ],
          ),
          const SizedBox(height: 18),
          if (reps == 0) ...[
            const Text(
              'Make sure your whole body is visible and you move through the full range.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.text2, fontSize: 13),
            ),
            const SizedBox(height: 14),
            AppButton(label: 'Try again', icon: Icons.refresh_rounded, onPressed: _again),
          ] else ...[
            AppButton(label: 'Save to leaderboard', icon: Icons.leaderboard_rounded, busy: saving, onPressed: _save),
            const SizedBox(height: 6),
            TextButton(onPressed: saving ? null : _again, child: const Text('Discard & try again')),
          ],
          if (saving && _clipNote != null)
            Text(_clipNote!, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
        ],
      ),
    );
  }

  Widget _donePanel(ArenaVisual v) {
    final r = _result!;
    final ex = widget.exercise;
    final a = r.attempt;
    return _sheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              gradient: AppColors.primaryGradient,
              shape: BoxShape.circle,
              boxShadow: AppShadows.glow(AppColors.primary),
            ),
            child: Icon(
              r.qualifiesTop10 ? Icons.military_tech_rounded : Icons.emoji_events_rounded,
              color: Colors.white,
              size: 40,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            r.qualifiesTop10
                ? "You're #${r.rank} in India!"
                : r.personalBest
                ? (r.previousBest == null ? 'First set on the board!' : 'New personal best!')
                : 'Set saved',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4),
          ),
          const SizedBox(height: 4),
          Text(
            '${ex.format(a.reps)}${a.completed && a.level != null ? ' · level ${ex.format(a.level!)} complete' : ''}',
            style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _stat('points', '+${r.pointsAwarded}'),
              _stat('India rank', r.rank == null ? '—' : '#${r.rank}'),
              _stat('best', r.previousBest == null || r.personalBest ? ex.format(a.reps) : ex.format(r.previousBest!)),
            ],
          ),
          if (r.pointsAwarded == 0 || r.dailyCapReached) ...[
            const SizedBox(height: 10),
            Text(
              r.levelPoints == 0
                  ? 'Complete a level to earn points.'
                  : r.dailyCapReached
                  ? 'Daily ${ex.name} points maxed (${ex.dailyPointsCap}) — come back tomorrow for more.'
                  : '',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.text3, fontSize: 12.5),
            ),
          ],
          if (_clipNote != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  _clipFailed ? Icons.error_outline_rounded : Icons.videocam_rounded,
                  size: 18,
                  color: _clipFailed ? AppColors.red : AppColors.green,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_clipNote!, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                ),
                if (_clipFailed) TextButton(onPressed: _retryClip, child: const Text('Retry')),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 54,
                  child: OutlinedButton.icon(
                    onPressed: _again,
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('Another set'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AppButton(label: 'Done', onPressed: () => Navigator.pop(context, true)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
