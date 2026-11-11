import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../data/rse_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../bookings/paid_via.dart' show PaidViaTag;

/// Front-desk scanner (BRD §10.1): scans the member's FitKey QR and checks them in
/// (POST /partner/venues/:id/checkin/scan). A typed code works too, for devices without a camera.
class ScanCheckinScreen extends StatefulWidget {
  const ScanCheckinScreen({super.key, required this.venueId, required this.venueName});

  final String venueId;
  final String venueName;

  @override
  State<ScanCheckinScreen> createState() => _ScanCheckinScreenState();
}

class _ScanCheckinScreenState extends State<ScanCheckinScreen> {
  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _busy = false;
  String? _lastCode;
  ({bool ok, String title, String? detail, String? paidVia})? _result;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(String code) async {
    code = code.trim();
    if (code.isEmpty || _busy || code == _lastCode) return;
    setState(() {
      _busy = true;
      _lastCode = code;
    });
    try {
      final r = await context.read<PartnerSession>().api.scanCheckin(widget.venueId, code);
      HapticFeedback.mediumImpact();
      if (mounted) {
        setState(
          () => _result = (
            ok: true,
            title: r.memberName == null ? 'Checked in' : '${r.memberName} checked in',
            detail: r.message,
            paidVia: r.paidVia,
          ),
        );
      }
    } catch (e) {
      HapticFeedback.heavyImpact();
      if (mounted) {
        setState(() => _result = (ok: false, title: 'Not checked in', detail: friendlyError(e), paidVia: null));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      // Allow the same code again after a short pause (e.g. retry after fixing a plan).
      Future.delayed(const Duration(seconds: 3), () => _lastCode = null);
    }
  }

  Future<void> _typeCode() async {
    final c = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter member code'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'Code from the member\'s app'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Check in')),
        ],
      ),
    ).whenComplete(c.dispose);
    if (code != null) {
      _lastCode = null;
      await _submit(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Scan check-in', style: TextStyle(color: Colors.white)),
            Text(
              widget.venueName,
              style: const TextStyle(fontSize: 12.5, color: Colors.white70, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Torch',
            onPressed: () => _controller.toggleTorch(),
            icon: const Icon(Icons.flashlight_on_rounded),
          ),
          IconButton(
            tooltip: 'Switch camera',
            onPressed: () => _controller.switchCamera(),
            icon: const Icon(Icons.cameraswitch_rounded),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: (capture) {
                final code = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
                if (code != null) _submit(code);
              },
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Camera unavailable (${error.errorCode.name}). Allow camera access, or type the member\'s code.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.lime, width: 3),
                borderRadius: BorderRadius.circular(24),
              ),
              child: _busy ? const Center(child: CircularProgressIndicator(color: AppColors.lime)) : null,
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (r != null)
                    AppCard(
                      color: r.ok ? AppColors.greenSoft : AppColors.redSoft,
                      child: Row(
                        children: [
                          Icon(
                            r.ok ? Icons.check_circle_rounded : Icons.error_rounded,
                            color: r.ok ? AppColors.green : AppColors.red,
                            size: 36,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(r.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                if (r.detail != null)
                                  Text(r.detail!, style: const TextStyle(color: AppColors.text2, fontSize: 13)),
                              ],
                            ),
                          ),
                          if (r.paidVia != null) PaidViaTag(r.paidVia),
                        ],
                      ),
                    )
                  else
                    const Text(
                      'Point the camera at the member\'s FitKey QR',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  const SizedBox(height: 12),
                  AppButton(
                    label: 'Type code instead',
                    icon: Icons.keyboard_rounded,
                    color: Colors.white,
                    foreground: AppColors.ink,
                    height: 48,
                    onPressed: _busy ? null : _typeCode,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
