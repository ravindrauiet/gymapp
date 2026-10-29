import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
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

enum _Phase { loading, error, ready, countdown, active, review, saving, done }

const _deviceDegrees = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

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
  final _detector = PoseDetector(options: PoseDetectorOptions(mode: PoseDetectionMode.stream, model: PoseDetectionModel.base));

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keep the screen awake during long sets (e.g. a 2-minute plank).
    WakelockPlus.enable().catchError((_) {});
    _init();
  }

  @override
  void dispose() {
    WakelockPlus.disable().catchError((_) {});
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _countdownTimer?.cancel();
    _segmentTimer?.cancel();
    final c = _c;
    _c = null;
    c?.dispose();
    _detector.close();
    _deleteFile(_prevSegment);
    _deleteFile(_clip);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (_phase == _Phase.active) {
        _finish();
      } else if (_phase == _Phase.ready || _phase == _Phase.countdown) {
        _countdownTimer?.cancel();
        _releaseCamera();
        setState(() => _phase = _Phase.loading);
      }
    } else if (state == AppLifecycleState.resumed && _phase == _Phase.loading && _c == null) {
      _init();
    }
  }

  // ---------------------------------------------------------------------------------------------- camera

  Future<void> _init() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
      _permissionDenied = false;
    });
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw CameraException('NoCamera', 'No camera found on this device');
      final cam = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first);
      final c = CameraController(
        cam,
        ResolutionPreset.medium, // ~480p: enough for pose landmarks, keeps proof clips small
        enableAudio: false,
        videoBitrate: 900000, // ≈ 6.75 MB per minute → a 45 s segment stays well under 12 MB
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      _c = c;
      await _startPreviewStream();
      if (!mounted) return;
      setState(() => _phase = _Phase.ready);
    } on CameraException catch (e) {
      if (!mounted) return;
      final denied = e.code.contains('AccessDenied') || e.code.contains('Restricted') || e.code == 'cameraPermission';
      setState(() {
        _phase = _Phase.error;
        _permissionDenied = denied;
        _error = denied
            ? 'FITKEY needs camera access to count your reps. Nothing is recorded unless your set makes the top 10.'
            : (e.description ?? 'The camera could not be started.');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = 'The camera could not be started.';
      });
    }
  }

  Future<void> _releaseCamera() async {
    final c = _c;
    _c = null;
    _streaming = false;
    _recording = false;
    _segmentTimer?.cancel();
    await c?.dispose();
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

    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(cam.sensorOrientation);
    } else {
      final device = _deviceDegrees[c.value.deviceOrientation] ?? 0;
      final comp = cam.lensDirection == CameraLensDirection.front
          ? (cam.sensorOrientation + device) % 360
          : (cam.sensorOrientation - device + 360) % 360;
      rotation = InputImageRotationValue.fromRawValue(comp);
    }
    if (rotation == null) return null;

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
    if (_busy || !mounted) return;
    final input = _toInputImage(image);
    if (input == null) return;
    _busy = true;
    _detector.processImage(input).then((poses) {
      if (!mounted) return;
      final frame = poses.isEmpty ? null : _toFrame(poses.first);
      if (_phase == _Phase.active) {
        final before = _counter.reps;
        _counter.update(frame, _active.elapsed);
        if (_counter.reps > before) _onRep();
      }
      setState(() => _pose = frame);
    }).catchError((Object e) {
      debugPrint('Arena: pose detection failed ($e)');
    }).whenComplete(() => _busy = false);
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
    await _startRecording();
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
        _clipNote = 'This phone could not record a proof clip — your set is saved without one.';
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
        content: Text(_counter.reps > 0
            ? 'Your ${widget.exercise.format(_counter.reps)} will not be saved to the leaderboard.'
            : 'Nothing has been counted yet.'),
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
        body: Stack(fit: StackFit.expand, children: [
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
          if (_phase == _Phase.active) ..._activeOverlay(v),
          if (_phase == _Phase.countdown) _countdownOverlay(),
          if (_phase == _Phase.ready) Align(alignment: Alignment.bottomCenter, child: _readyPanel(v)),
          if (_phase == _Phase.review || _phase == _Phase.saving)
            Align(alignment: Alignment.bottomCenter, child: _reviewPanel(v)),
          if (_phase == _Phase.done) Align(alignment: Alignment.bottomCenter, child: _donePanel(v)),
        ]),
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
        decoration: BoxDecoration(color: color ?? Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(20)),
        child: child,
      );

  Widget _topBar(ArenaVisual v) {
    final level = widget.level;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(children: [
        _circleButton(Icons.close_rounded, _close),
        const SizedBox(width: 10),
        Flexible(
          child: _pill(Text(
            level == null ? widget.exercise.name : '${widget.exercise.name} · ${widget.exercise.format(level.target)}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
          )),
        ),
        const Spacer(),
        if (_phase == _Phase.active) ...[
          if (_recording)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _pill(
                const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.fiber_manual_record_rounded, color: AppColors.red, size: 12),
                  SizedBox(width: 4),
                  Text('REC', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 11)),
                ]),
              ),
            ),
          _pill(Text(_clock(_active.elapsed),
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]))),
        ],
      ]),
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
            child: Row(children: [
              Icon(
                  switch (cue.tone) {
                    CueTone.good => Icons.check_circle_rounded,
                    CueTone.warn => Icons.warning_amber_rounded,
                    CueTone.info => Icons.info_outline_rounded,
                  },
                  color: Colors.white,
                  size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(cue.text,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14.5)),
              ),
            ]),
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
                boxShadow: AppShadows.glow(AppColors.primary)),
            child: Row(children: [
              const Icon(Icons.emoji_events_rounded, color: Colors.white, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Level complete — ${widget.exercise.format(t!)}!',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                  const Text('Keep going for a bigger set, or tap Finish.',
                      style: TextStyle(color: Colors.white, fontSize: 12.5)),
                ]),
              ),
            ]),
          ),
        ),
      // Big counter + finish
      Positioned(
        left: 16,
        right: 16,
        bottom: MediaQuery.paddingOf(context).bottom + 16,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 168,
            height: 168,
            child: Stack(alignment: Alignment.center, children: [
              Container(decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle)),
              if (progress != null)
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 8,
                    color: _levelDone ? AppColors.lime : v.color,
                    backgroundColor: Colors.white.withValues(alpha: 0.18),
                  ),
                ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                TweenAnimationBuilder<double>(
                  key: ValueKey(_counter.reps),
                  tween: Tween(begin: 1.25, end: 1),
                  duration: const Duration(milliseconds: 250),
                  builder: (_, s, child) => Transform.scale(scale: s, child: child),
                  child: Text('${_counter.reps}',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 64, fontWeight: FontWeight.w800, height: 1, letterSpacing: -2)),
                ),
                Text(
                  t == null
                      ? (widget.exercise.timed ? 'seconds' : 'reps')
                      : '/ ${widget.exercise.format(t)}',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontWeight: FontWeight.w700),
                ),
              ]),
            ]),
          ),
          if (_counter.partialReps > 0) ...[
            const SizedBox(height: 8),
            _pill(Text(
              widget.exercise.timed
                  ? '${_counter.partialReps} form ${_counter.partialReps == 1 ? 'break' : 'breaks'}'
                  : '${_counter.partialReps} partial ${_counter.partialReps == 1 ? 'rep' : 'reps'} not counted',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
            )),
          ],
          const SizedBox(height: 14),
          AppButton(
            label: _levelDone ? 'Finish & save' : 'Finish',
            icon: Icons.flag_rounded,
            color: _levelDone ? AppColors.green : AppColors.surface,
            foreground: _levelDone ? Colors.white : AppColors.ink,
            onPressed: _finish,
          ),
        ]),
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
          child: Text('$_countdown',
              style: const TextStyle(color: Colors.white, fontSize: 140, fontWeight: FontWeight.w800, height: 1)),
        ),
      );

  Widget _sheet({required Widget child}) => Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(20, 18, 20, 16 + MediaQuery.paddingOf(context).bottom),
        child: child,
      );

  Widget _readyPanel(ArenaVisual v) {
    final ex = widget.exercise;
    final seen = _pose != null && _pose!.values.where((p) => p.likelihood >= kMinLikelihood).length >= 8;
    return _sheet(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBubble(seen ? Icons.check_rounded : Icons.person_search_rounded,
              color: seen ? AppColors.green : v.color, bg: seen ? AppColors.greenSoft : v.soft),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(seen ? 'We can see you — ready when you are' : 'Get your whole body in the frame',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 2),
              Text(ex.howTo.isNotEmpty ? ex.howTo.first : 'Prop your phone up and step back.',
                  style: const TextStyle(color: AppColors.text2, fontSize: 13, height: 1.35)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        const Row(children: [
          Icon(Icons.lock_outline_rounded, size: 15, color: AppColors.text3),
          SizedBox(width: 6),
          Expanded(
            child: Text('Reps are counted on your phone. A short clip is uploaded only if your set makes the all-India top 10.',
                style: TextStyle(color: AppColors.text3, fontSize: 11.5, height: 1.35)),
          ),
        ]),
        const SizedBox(height: 14),
        AppButton(label: 'Start · 3-2-1', icon: Icons.play_arrow_rounded, onPressed: _startCountdown),
      ]),
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(children: [
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _reviewPanel(ArenaVisual v) {
    final ex = widget.exercise;
    final reps = _counter.reps;
    final t = _target;
    final done = t != null && reps >= t;
    final saving = _phase == _Phase.saving;
    return _sheet(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        IconBubble(done ? Icons.emoji_events_rounded : Icons.flag_rounded,
            color: done ? AppColors.amber : v.color, bg: done ? AppColors.amberSoft : v.soft, size: 56),
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
        Row(children: [
          _stat(ex.timed ? 'held' : 'reps', ex.timed ? '${reps}s' : '$reps'),
          _stat('time', _clock(_active.elapsed)),
          _stat(ex.timed ? 'form breaks' : 'not counted', '${_counter.partialReps}'),
        ]),
        const SizedBox(height: 18),
        if (reps == 0) ...[
          const Text('Make sure your whole body is visible and you move through the full range.',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.text2, fontSize: 13)),
          const SizedBox(height: 14),
          AppButton(label: 'Try again', icon: Icons.refresh_rounded, onPressed: _again),
        ] else ...[
          AppButton(label: 'Save to leaderboard', icon: Icons.leaderboard_rounded, busy: saving, onPressed: _save),
          const SizedBox(height: 6),
          TextButton(
            onPressed: saving ? null : _again,
            child: const Text('Discard & try again'),
          ),
        ],
        if (saving && _clipNote != null)
          Text(_clipNote!, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
      ]),
    );
  }

  Widget _donePanel(ArenaVisual v) {
    final r = _result!;
    final ex = widget.exercise;
    final a = r.attempt;
    return _sheet(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
              gradient: AppColors.primaryGradient, shape: BoxShape.circle, boxShadow: AppShadows.glow(AppColors.primary)),
          child: Icon(r.qualifiesTop10 ? Icons.military_tech_rounded : Icons.emoji_events_rounded, color: Colors.white, size: 40),
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
        Row(children: [
          _stat('points', '+${r.pointsAwarded}'),
          _stat('India rank', r.rank == null ? '—' : '#${r.rank}'),
          _stat('best', r.previousBest == null || r.personalBest ? ex.format(a.reps) : ex.format(r.previousBest!)),
        ]),
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
          Row(children: [
            Icon(_clipFailed ? Icons.error_outline_rounded : Icons.videocam_rounded,
                size: 18, color: _clipFailed ? AppColors.red : AppColors.green),
            const SizedBox(width: 6),
            Expanded(child: Text(_clipNote!, style: const TextStyle(color: AppColors.text2, fontSize: 12.5))),
            if (_clipFailed) TextButton(onPressed: _retryClip, child: const Text('Retry')),
          ]),
        ],
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 54,
              child: OutlinedButton.icon(
                  onPressed: _again, icon: const Icon(Icons.replay_rounded), label: const Text('Another set')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: AppButton(label: 'Done', onPressed: () => Navigator.pop(context, true))),
        ]),
      ]),
    );
  }
}
