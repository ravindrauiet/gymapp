import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart' show ApiException, formatClock, formatDayDate;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../community/buddy_screens.dart';
import '../health/attendance_screen.dart';
import '../plans/plans_screen.dart';

const _windowSize = 250.0;
const _windowRadius = 28.0;

/// U4 — scan the venue's QR code (or enter the venue OTP) to mark attendance.
class CheckinScreen extends StatefulWidget {
  const CheckinScreen({super.key, this.venueId, this.venueName});

  /// Pre-selects the venue for the OTP fallback (when opened from a venue page).
  final String? venueId;
  final String? venueName;

  @override
  State<CheckinScreen> createState() => _CheckinScreenState();
}

class _CheckinScreenState extends State<CheckinScreen> with SingleTickerProviderStateMixin {
  final _scanner = MobileScannerController(detectionSpeed: DetectionSpeed.normal);
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
    ..repeat(reverse: true);

  bool _busy = false;
  bool _sheetOpen = false;
  String? _lastRejected;
  DateTime _rejectedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _anim.dispose();
    _scanner.dispose();
    super.dispose();
  }

  // ---- Flow --------------------------------------------------------------

  void _onDetect(BarcodeCapture capture) {
    final value = capture.barcodes.firstOrNull?.rawValue;
    if (value == null || _busy || _sheetOpen) return;
    // Ignore the same rejected code for a few seconds so we don't spam errors while it stays in frame.
    if (value == _lastRejected && DateTime.now().difference(_rejectedAt) < const Duration(seconds: 4)) return;
    if (!value.startsWith('FITKEY:')) {
      _reject(value);
      toast(context, "That's not a FITKEY check-in code", error: true, icon: Icons.qr_code_2_rounded);
      return;
    }
    _submitQr(value);
  }

  void _reject(String value) {
    _lastRejected = value;
    _rejectedAt = DateTime.now();
  }

  Future<void> _submitQr(String value) async {
    setState(() => _busy = true);
    final api = context.read<Session>().api;
    try {
      final checkin = await api.checkinWithQr(value);
      if (!mounted) return;
      await _success(checkin);
    } catch (e) {
      _reject(value);
      if (!mounted) return;
      setState(() => _busy = false);
      await _handleError(e);
    }
  }

  Future<void> _success(Checkin checkin) async {
    HapticFeedback.heavyImpact();
    // Keep the pass card / home in sync (streaks, plan state).
    unawaited(context.read<Session>().refresh().catchError((_) {}));
    await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => CheckinSuccessScreen(checkin: checkin)));
  }

  Future<void> _handleError(Object e) async {
    HapticFeedback.vibrate();
    if (e is ApiException && e.needsPlan) {
      await _showProblem(
        icon: Icons.lock_rounded,
        color: AppColors.amber,
        title: 'This venue needs a FITKEY Pass',
        message: '${e.message}. Pick a plan that covers this venue and you can check in right away.',
        cta: 'See plans',
        onCta: () => push(context, const PlansScreen()),
      );
    } else if (e is ApiException && e.statusCode == 409) {
      await _showProblem(
        icon: Icons.event_available_rounded,
        color: AppColors.green,
        title: "You're already checked in",
        message: '${e.message}. Enjoy your workout — see you tomorrow!',
        cta: 'View attendance',
        onCta: () => push(context, const AttendanceScreen()),
      );
    } else {
      toast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _showProblem({
    required IconData icon,
    required Color color,
    required String title,
    required String message,
    required String cta,
    required VoidCallback onCta,
  }) async {
    _sheetOpen = true;
    final go = await showAppSheet<bool>(
      context,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: IconBubble(icon, color: color, size: 72)),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.text2, height: 1.45)),
            const SizedBox(height: 22),
            AppButton(label: cta, onPressed: () => Navigator.pop(ctx, true)),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: TextButton.styleFrom(foregroundColor: AppColors.text2),
              child: const Text('Not now'),
            ),
          ]),
        ),
      ),
    );
    _sheetOpen = false;
    if (go == true && mounted) onCta();
  }

  Future<void> _openOtp() async {
    _sheetOpen = true;
    final result = await showAppSheet<Object>(
      context,
      builder: (_) => _OtpSheet(initialVenueId: widget.venueId, initialVenueName: widget.venueName),
    );
    _sheetOpen = false;
    if (!mounted) return;
    if (result is Checkin) {
      await _success(result);
    } else if (result != null) {
      await _handleError(result);
    }
  }

  // ---- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          MobileScanner(
            controller: _scanner,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _CameraError(
              denied: error.errorCode == MobileScannerErrorCode.permissionDenied,
              onOtp: _openOtp,
            ),
          ),
          // Dark overlay with a rounded cut-out
          IgnorePointer(
            child: CustomPaint(painter: _OverlayPainter(), child: const SizedBox.expand()),
          ),
          // Animated corners + scan line
          Center(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _anim,
                builder: (context, _) {
                  final t = Curves.easeInOut.transform(_anim.value);
                  return SizedBox(
                    width: _windowSize + 6 * t,
                    height: _windowSize + 6 * t,
                    child: Stack(children: [
                      CustomPaint(painter: _CornersPainter(), size: Size.infinite),
                      if (!_busy)
                        Positioned(
                          left: 18,
                          right: 18,
                          top: 16 + (_windowSize - 40) * t,
                          child: Container(
                            height: 3,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(2),
                              gradient: LinearGradient(colors: [
                                AppColors.lime.withValues(alpha: 0),
                                AppColors.lime,
                                AppColors.lime.withValues(alpha: 0),
                              ]),
                              boxShadow: [BoxShadow(color: AppColors.lime.withValues(alpha: 0.6), blurRadius: 12)],
                            ),
                          ),
                        ),
                    ]),
                  );
                },
              ),
            ),
          ),
          // Top bar
          Positioned(
            top: top + 6,
            left: 8,
            right: 8,
            child: Row(children: [
              _GlassButton(icon: Icons.close_rounded, tooltip: 'Close', onTap: () => Navigator.maybePop(context)),
              const Expanded(
                child: Text('Check in',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              ValueListenableBuilder<MobileScannerState>(
                valueListenable: _scanner,
                builder: (context, state, _) {
                  final on = state.torchState == TorchState.on;
                  final available = state.torchState != TorchState.unavailable;
                  return _GlassButton(
                    icon: on ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
                    tooltip: 'Torch',
                    active: on,
                    onTap: available ? () => _scanner.toggleTorch() : null,
                  );
                },
              ),
            ]),
          ),
          // Prompt above the window
          Align(
            alignment: const Alignment(0, -0.62),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Scan the venue QR',
                    style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                const SizedBox(height: 6),
                Text("It's displayed at the front desk of every FITKEY venue",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13.5)),
              ]),
            ),
          ),
          // Bottom panel
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.paddingOf(context).bottom + 20,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (widget.venueName != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Tag('At ${widget.venueName}',
                      icon: Icons.storefront_rounded, color: Colors.white, bg: Colors.white.withValues(alpha: 0.14)),
                ),
              Tap(
                onTap: _busy ? null : _openOtp,
                child: Container(
                  height: 56,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.pin_rounded, color: AppColors.ink),
                    SizedBox(width: 10),
                    Text('Enter OTP instead',
                        style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w800, fontSize: 15.5)),
                  ]),
                ),
              ),
              const SizedBox(height: 10),
              Text('QR not working? Ask the desk for the 6-digit code.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12.5)),
            ]),
          ),
          if (_busy)
            Container(
              color: Colors.black.withValues(alpha: 0.6),
              child: const Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(color: AppColors.lime, strokeWidth: 3.5)),
                  SizedBox(height: 16),
                  Text('Checking you in…',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({required this.icon, required this.tooltip, required this.onTap, this.active = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Tap(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: active ? AppColors.lime : Colors.white.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
          child: Icon(icon,
              color: active ? AppColors.ink : Colors.white.withValues(alpha: onTap == null ? 0.4 : 1), size: 22),
        ),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.denied, required this.onOtp});
  final bool denied;
  final VoidCallback onOtp;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.ink,
      padding: const EdgeInsets.all(32),
      alignment: Alignment.center,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        IconBubble(Icons.no_photography_rounded, color: AppColors.lime, bg: Colors.white.withValues(alpha: 0.08), size: 72),
        const SizedBox(height: 16),
        Text(denied ? 'Camera access needed' : 'Camera unavailable',
            style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          denied
              ? 'Allow camera access in Settings to scan, or check in with the venue OTP.'
              : "We couldn't start the camera. You can still check in with the venue OTP.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7), height: 1.4),
        ),
        const SizedBox(height: 180),
      ]),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final window = RRect.fromRectAndRadius(
      Rect.fromCenter(center: size.center(Offset.zero), width: _windowSize, height: _windowSize),
      const Radius.circular(_windowRadius),
    );
    final path = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRRect(window),
    );
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.62));
    canvas.drawRRect(window, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.18));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CornersPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const len = 34.0;
    const r = _windowRadius;
    final p = Paint()
      ..color = AppColors.lime
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final w = size.width, h = size.height;
    // top-left
    canvas.drawPath(
        Path()
          ..moveTo(0, r + len - r)
          ..lineTo(0, r)
          ..arcToPoint(const Offset(r, 0), radius: const Radius.circular(r))
          ..lineTo(len, 0),
        p);
    // top-right
    canvas.drawPath(
        Path()
          ..moveTo(w - len, 0)
          ..lineTo(w - r, 0)
          ..arcToPoint(Offset(w, r), radius: const Radius.circular(r))
          ..lineTo(w, len),
        p);
    // bottom-right
    canvas.drawPath(
        Path()
          ..moveTo(w, h - len)
          ..lineTo(w, h - r)
          ..arcToPoint(Offset(w - r, h), radius: const Radius.circular(r))
          ..lineTo(w - len, h),
        p);
    // bottom-left
    canvas.drawPath(
        Path()
          ..moveTo(len, h)
          ..lineTo(r, h)
          ..arcToPoint(Offset(0, h - r), radius: const Radius.circular(r))
          ..lineTo(0, h - len),
        p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// OTP fallback
// ---------------------------------------------------------------------------

/// Pops with a [Checkin] on success, or with the error for plan / duplicate problems the screen explains.
class _OtpSheet extends StatefulWidget {
  const _OtpSheet({this.initialVenueId, this.initialVenueName});

  final String? initialVenueId;
  final String? initialVenueName;

  @override
  State<_OtpSheet> createState() => _OtpSheetState();
}

class _OtpSheetState extends State<_OtpSheet> {
  final _otp = TextEditingController();
  final _focus = FocusNode();
  late String? _venueId = widget.initialVenueId;
  late String? _venueName = widget.initialVenueName;
  bool _busy = false;
  String? _error;

  bool get _ready => _venueId != null && _otp.text.length == 6 && !_busy;

  Future<void> _pickVenue() async {
    final picked = await pickVenue(context);
    if (picked == null || !mounted) return;
    setState(() {
      _venueId = picked.id;
      _venueName = picked.name;
      _error = null;
    });
    _focus.requestFocus();
  }

  Future<void> _submit() async {
    if (!_ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final checkin = await context.read<Session>().api.checkinWithOtp(_venueId!, _otp.text);
      if (mounted) Navigator.pop(context, checkin);
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && (e.needsPlan || e.statusCode == 409)) {
        Navigator.pop(context, e);
        return;
      }
      HapticFeedback.vibrate();
      setState(() {
        _busy = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  void dispose() {
    _otp.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Row(children: [
            IconBubble(Icons.pin_rounded, color: AppColors.purple, size: 46),
            SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Check in with OTP', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                SizedBox(height: 2),
                Text('Ask the front desk for the 6-digit FITKEY code',
                    style: TextStyle(color: AppColors.text2, fontSize: 13, fontWeight: FontWeight.w500)),
              ]),
            ),
          ]),
          const SizedBox(height: 20),
          Tap(
            onTap: _busy ? null : _pickVenue,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _venueId == null ? AppColors.primary : AppColors.line, width: 1.2),
              ),
              child: Row(children: [
                IconBubble(Icons.storefront_rounded, color: _venueId == null ? AppColors.primary : AppColors.green, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('VENUE',
                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: AppColors.text3, letterSpacing: 1.2)),
                    const SizedBox(height: 2),
                    Text(_venueName ?? 'Select the venue you are at',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: _venueName == null ? AppColors.text2 : AppColors.text)),
                  ]),
                ),
                Text(_venueId == null ? 'Choose' : 'Change',
                    style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 13)),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          _OtpBoxes(controller: _otp, focusNode: _focus, autofocus: _venueId != null, onChanged: (_) {
            setState(() => _error = null);
            if (_ready) _submit();
          }),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: AppColors.redSoft, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                const Icon(Icons.error_outline_rounded, color: AppColors.red, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error!,
                      style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w600, fontSize: 13)),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          AppButton(
            label: 'Check in',
            icon: Icons.login_rounded,
            busy: _busy,
            onPressed: _ready ? _submit : null,
          ),
        ]),
      ),
    );
  }
}

/// Six visual boxes over a single hidden text field.
class _OtpBoxes extends StatelessWidget {
  const _OtpBoxes({required this.controller, required this.focusNode, required this.onChanged, this.autofocus = false});
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // Invisible field that actually receives input.
      Opacity(
        opacity: 0,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          onChanged: onChanged,
          showCursor: false,
          enableInteractiveSelection: false,
        ),
      ),
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: focusNode.requestFocus,
          child: ListenableBuilder(
            listenable: Listenable.merge([controller, focusNode]),
            builder: (context, _) {
              final text = controller.text;
              return Row(children: [
                for (var i = 0; i < 6; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: i < text.length ? AppColors.primarySoft : AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: focusNode.hasFocus && i == text.length.clamp(0, 5) ? AppColors.primary : Colors.transparent,
                          width: 1.6,
                        ),
                      ),
                      child: Text(i < text.length ? text[i] : '',
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ]);
            },
          ),
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Venue picker
// ---------------------------------------------------------------------------

/// Bottom-sheet venue search used by OTP check-in and the buddy planner.
Future<VenueSummary?> pickVenue(BuildContext context) {
  return showAppSheet<VenueSummary>(context, builder: (_) => const _VenuePickerSheet());
}

class _VenuePickerSheet extends StatefulWidget {
  const _VenuePickerSheet();

  @override
  State<_VenuePickerSheet> createState() => _VenuePickerSheetState();
}

class _VenuePickerSheetState extends State<_VenuePickerSheet> {
  final _q = TextEditingController();
  Timer? _debounce;
  late Future<List<VenueSummary>> _future = _load();

  Future<List<VenueSummary>> _load() => context.read<Session>().api.venues(q: _q.text.trim(), limit: 30);

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _future = _load());
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Choose venue', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: RotatingSearchBar(
            hints: const ["'gym name'", "'area'", "'swimming pool'", "'yoga studio'"],
            controller: _q,
            autofocus: true,
            onChanged: _onChanged,
            onSubmitted: _onChanged,
          ),
        ),
        Expanded(
          child: AsyncBody<List<VenueSummary>>(
            future: _future,
            onRetry: () => setState(() => _future = _load()),
            loading: const SkeletonList(count: 5, itemHeight: 56),
            builder: (context, venues) => venues.isEmpty
                ? EmptyView(
                    icon: Icons.search_off_rounded,
                    title: 'No venues found',
                    message: _q.text.isEmpty ? 'No live venues yet.' : 'Try a different name or area.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: venues.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final v = venues[i];
                      final cat = venueVisual(v.categories.firstOrNull ?? '');
                      return Tap(
                        onTap: () => Navigator.pop(context, v),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.line),
                          ),
                          child: Row(children: [
                            NetImage(v.coverPhoto, fallback: cat.image, width: 52, height: 52, radius: 12),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(v.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w800)),
                                const SizedBox(height: 2),
                                Text(
                                  [cat.label, if (v.location.isNotEmpty) v.location].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                                ),
                              ]),
                            ),
                            const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Success
// ---------------------------------------------------------------------------

class CheckinSuccessScreen extends StatefulWidget {
  const CheckinSuccessScreen({super.key, required this.checkin});

  final Checkin checkin;

  @override
  State<CheckinSuccessScreen> createState() => _CheckinSuccessScreenState();
}

class _CheckinSuccessScreenState extends State<CheckinSuccessScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
    ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.checkin;
    final pop = CurvedAnimation(parent: _c, curve: const Interval(0, 0.55, curve: Curves.elasticOut));
    final ripple = CurvedAnimation(parent: _c, curve: const Interval(0.1, 1, curve: Curves.easeOut));
    final fadeUp = CurvedAnimation(parent: _c, curve: const Interval(0.35, 0.85, curve: Curves.easeOut));

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            const Spacer(),
            SizedBox(
              width: 200,
              height: 200,
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => Stack(alignment: Alignment.center, children: [
                  for (final k in const [1.0, 0.72])
                    Opacity(
                      opacity: (1 - ripple.value).clamp(0.0, 1.0) * 0.5,
                      child: Container(
                        width: 120 + 80 * ripple.value * k,
                        height: 120 + 80 * ripple.value * k,
                        decoration: const BoxDecoration(color: AppColors.greenSoft, shape: BoxShape.circle),
                      ),
                    ),
                  Transform.scale(
                    scale: pop.value,
                    child: Container(
                      width: 116,
                      height: 116,
                      decoration: BoxDecoration(
                        color: AppColors.green,
                        shape: BoxShape.circle,
                        boxShadow: AppShadows.glow(AppColors.green),
                      ),
                      child: const Icon(Icons.check_rounded, size: 66, color: Colors.white),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 18),
            FadeTransition(
              opacity: fadeUp,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(fadeUp),
                child: Column(children: [
                  const Text("You're checked in!",
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
                  const SizedBox(height: 6),
                  const Text('Have a great workout 💪',
                      style: TextStyle(color: AppColors.text2, fontSize: 15, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 24),
                  AppCard(
                    child: Column(children: [
                      Row(children: [
                        const IconBubble(Icons.storefront_rounded, color: AppColors.green, size: 46),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(c.venueName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                            if (c.venueArea != null)
                              Text(c.venueArea!, style: const TextStyle(color: AppColors.text2, fontSize: 13)),
                          ]),
                        ),
                        Tag(c.method == 'qr' ? 'QR' : 'OTP',
                            icon: c.method == 'qr' ? Icons.qr_code_2_rounded : Icons.pin_rounded,
                            color: AppColors.blue,
                            dense: true),
                      ]),
                      const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Divider()),
                      Row(children: [
                        Expanded(child: _Info(icon: Icons.schedule_rounded, label: 'Time', value: formatClock(c.checkedInAt))),
                        Expanded(
                            child: _Info(icon: Icons.today_rounded, label: 'Date', value: formatDayDate(c.checkedInAt))),
                        Expanded(child: _Info(icon: Icons.key_rounded, label: 'Plan', value: c.planName ?? 'FITKEY Pass')),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.emoji_events_rounded, size: 16, color: AppColors.amber),
                    SizedBox(width: 6),
                    Text('Counts towards your streak & leaderboard',
                        style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700, fontSize: 12.5)),
                  ]),
                ]),
              ),
            ),
            const Spacer(),
            AppButton(label: 'Done', onPressed: () => Navigator.pop(context)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pushReplacement(
                      context, MaterialPageRoute(builder: (_) => const CreateBuddyPostScreen())),
                  icon: const Icon(Icons.group_add_rounded, size: 20),
                  label: const Text('Find a gym buddy'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pushReplacement(
                      context, MaterialPageRoute(builder: (_) => const AttendanceScreen())),
                  icon: const Icon(Icons.history_rounded, size: 20),
                  label: const Text('Attendance'),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Icon(icon, size: 18, color: AppColors.text3),
      const SizedBox(height: 4),
      Text(value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
      Text(label, style: const TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w600)),
    ]);
  }
}
