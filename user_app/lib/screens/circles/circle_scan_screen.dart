import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../data/circles_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'circles_common.dart';

const _qrPrefix = 'FITKEY-CIRCLE:';

/// Opens the scanner; returns the attendance result when a circle QR was accepted.
Future<CircleAttendResult?> scanCircleQr(BuildContext context) async {
  final result = await push<CircleAttendResult>(context, const CircleScanScreen());
  if (result != null && context.mounted) {
    final p = CirclesPrefs.instance;
    toast(
      context,
      result.joinedNow
          ? p.t('joinedAndAttended', {'name': result.circleName})
          : p.t('attendedMsg', {'name': result.circleName, 'n': result.streak}),
      icon: Icons.check_circle_rounded,
    );
  }
  return result;
}

/// One-tap "I'm here": uses the phone's location near the circle's pin, falls back to the QR scanner.
/// Returns true when attendance was marked.
Future<bool> attendHere(BuildContext context, CircleSummary circle) async {
  final p = CirclesPrefs.instance;
  final api = context.read<Session>().api;
  if (kIsWeb) {
    toast(context, p.t('webLocation'));
    return false;
  }
  if (circle.lat == null) return (await scanCircleQr(context)) != null;
  toast(context, p.t('locating'), icon: Icons.my_location_rounded);
  final pos = await currentPosition();
  if (!context.mounted) return false;
  if (pos == null) {
    toast(context, p.t('noLocation'), error: true);
    return (await scanCircleQr(context)) != null;
  }
  try {
    final r = await api.attendCircleHere(circle.id, lat: pos.latitude, lng: pos.longitude);
    if (!context.mounted) return true;
    HapticFeedback.mediumImpact();
    toast(context, p.t('attendedMsg', {'name': r.circleName, 'n': r.streak}), icon: Icons.check_circle_rounded);
    return true;
  } catch (e) {
    if (context.mounted) toast(context, friendlyError(e), error: true);
    return false;
  }
}

class CircleScanScreen extends StatefulWidget {
  const CircleScanScreen({super.key});

  @override
  State<CircleScanScreen> createState() => _CircleScanScreenState();
}

class _CircleScanScreenState extends State<CircleScanScreen> {
  final _scanner = kIsWeb ? null : MobileScannerController(detectionSpeed: DetectionSpeed.normal);
  bool _busy = false;
  String? _lastRejected;
  DateTime _rejectedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _scanner?.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    final value = capture.barcodes.firstOrNull?.rawValue;
    if (value == null || _busy) return;
    if (value == _lastRejected && DateTime.now().difference(_rejectedAt) < const Duration(seconds: 4)) return;
    if (!value.startsWith(_qrPrefix)) {
      _reject(value);
      toast(context, CirclesPrefs.instance.t('notCircleQr'), error: true, icon: Icons.qr_code_2_rounded);
      return;
    }
    _submit(value);
  }

  void _reject(String v) {
    _lastRejected = v;
    _rejectedAt = DateTime.now();
  }

  Future<void> _submit(String qr) async {
    setState(() => _busy = true);
    try {
      final r = await context.read<Session>().api.attendCircleQr(qr);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.pop(context, r);
    } catch (e) {
      if (!mounted) return;
      _reject(qr);
      toast(context, friendlyError(e), error: true);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CirclesShell(child: Builder(builder: (context) {
      final p = circlesOf(context);
      if (_scanner == null) {
        return Scaffold(
          appBar: AppBar(title: Text(p.t('scanTitle'))),
          backgroundColor: AppColors.bg,
          body: EmptyView(icon: Icons.qr_code_scanner_rounded, title: p.t('scanTitle'), message: p.t('webScan')),
        );
      }
      final top = MediaQuery.paddingOf(context).top;
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(fit: StackFit.expand, children: [
            MobileScanner(
              controller: _scanner,
              onDetect: _onDetect,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    error.errorCode == MobileScannerErrorCode.permissionDenied
                        ? 'Allow camera access in Settings to scan the circle QR.'
                        : 'The camera could not start. Ask your leader to mark you instead.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.4),
                  ),
                ),
              ),
            ),
            Center(
              child: IgnorePointer(
                child: Container(
                  width: 250,
                  height: 250,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: AppColors.lime, width: 4),
                  ),
                  child: _busy ? const Center(child: CircularProgressIndicator(color: AppColors.lime)) : null,
                ),
              ),
            ),
            Positioned(
              top: top + 8,
              left: 8,
              child: IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: Colors.black.withValues(alpha: 0.45)),
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                tooltip: p.t('cancel'),
              ),
            ),
            Align(
              alignment: const Alignment(0, -0.65),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(p.t('scanTitle'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text(p.t('scanSub'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 15, height: 1.35)),
                ]),
              ),
            ),
          ]),
        ),
      );
    }));
  }
}
