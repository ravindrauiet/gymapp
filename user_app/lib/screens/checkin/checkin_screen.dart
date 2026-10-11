import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import '../plans/plans_screen.dart';

/// U4 — scan the venue's QR code (or enter the venue OTP) to mark attendance.
class CheckinScreen extends StatefulWidget {
  const CheckinScreen({super.key, this.venueId, this.venueName});

  /// Pre-selects the venue for the OTP fallback (when opened from a venue page).
  final String? venueId;
  final String? venueName;

  @override
  State<CheckinScreen> createState() => _CheckinScreenState();
}

class _CheckinScreenState extends State<CheckinScreen> {
  final _scanner = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _useOtp = false;
  bool _busy = false;

  Future<void> _submit(Future<Checkin> Function() request) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final checkin = await request();
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => CheckinSuccessScreen(checkin: checkin)));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.needsPlan) {
        await _showNeedsPlan(e.message);
      } else {
        showSnack(context, e.message, error: true);
      }
      setState(() => _busy = false);
    }
  }

  void _onDetect(BarcodeCapture capture) {
    final value = capture.barcodes.firstOrNull?.rawValue;
    if (value == null || _busy) return;
    if (!value.startsWith('FITKEY:')) {
      showSnack(context, 'That\'s not a FITKEY check-in code', error: true);
      return;
    }
    _submit(() => context.read<Session>().api.checkinWithQr(value));
  }

  Future<void> _showNeedsPlan(String message) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.lock_outline, color: FkColors.orange, size: 36),
          title: const Text('Plan required'),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Not now')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const PlansScreen()));
              },
              child: const Text('See plans'),
            ),
          ],
        ),
      );

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Check in'),
        actions: [
          if (!_useOtp)
            IconButton(
              tooltip: 'Torch',
              icon: const Icon(Icons.flash_on),
              onPressed: () => _scanner.toggleTorch(),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.qr_code_scanner), label: Text('Scan QR')),
                ButtonSegment(value: true, icon: Icon(Icons.pin_outlined), label: Text('Enter OTP')),
              ],
              selected: {_useOtp},
              onSelectionChanged: (s) => setState(() => _useOtp = s.first),
            ),
          ),
          Expanded(
            child: _useOtp
                ? _OtpCheckin(
                    initialVenueId: widget.venueId,
                    initialVenueName: widget.venueName,
                    busy: _busy,
                    onSubmit: (venueId, otp) => _submit(() => context.read<Session>().api.checkinWithOtp(venueId, otp)),
                  )
                : _scannerView(),
          ),
        ],
      ),
    );
  }

  Widget _scannerView() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Stack(fit: StackFit.expand, children: [
              MobileScanner(
                controller: _scanner,
                onDetect: _onDetect,
                errorBuilder: (context, error) => Container(
                  color: FkColors.surface,
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      error.errorCode == MobileScannerErrorCode.permissionDenied
                          ? 'Camera permission is needed to scan. You can also use "Enter OTP".'
                          : 'Camera unavailable. Use "Enter OTP" instead.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: FkColors.textSecondary),
                    ),
                  ),
                ),
              ),
              Center(
                child: Container(
                  width: 230,
                  height: 230,
                  decoration: BoxDecoration(
                    border: Border.all(color: FkColors.lime, width: 3),
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
              if (_busy) Container(color: Colors.black54, child: const Center(child: CircularProgressIndicator())),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Point your camera at the QR code shown at the venue\'s front desk',
            textAlign: TextAlign.center, style: TextStyle(color: FkColors.textSecondary)),
      ]),
    );
  }
}

class _OtpCheckin extends StatefulWidget {
  const _OtpCheckin({this.initialVenueId, this.initialVenueName, required this.busy, required this.onSubmit});

  final String? initialVenueId;
  final String? initialVenueName;
  final bool busy;
  final void Function(String venueId, String otp) onSubmit;

  @override
  State<_OtpCheckin> createState() => _OtpCheckinState();
}

class _OtpCheckinState extends State<_OtpCheckin> {
  final _otp = TextEditingController();
  String? _venueId;
  String? _venueName;

  @override
  void initState() {
    super.initState();
    _venueId = widget.initialVenueId;
    _venueName = widget.initialVenueName;
  }

  Future<void> _pickVenue() async {
    final picked = await pickVenue(context);
    if (picked == null) return;
    setState(() {
      _venueId = picked.id;
      _venueName = picked.name;
    });
  }

  @override
  void dispose() {
    _otp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        const Text('Ask the front desk for the 6-digit FITKEY code shown in their Partner app.',
            style: TextStyle(color: FkColors.textSecondary)),
        const SizedBox(height: 20),
        Card(
          child: ListTile(
            leading: const Icon(Icons.storefront, color: FkColors.lime),
            title: Text(_venueName ?? 'Select venue',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: _venueName == null ? FkColors.textSecondary : null)),
            trailing: const Icon(Icons.expand_more),
            onTap: _pickVenue,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _otp,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          style: const TextStyle(fontSize: 26, letterSpacing: 12, fontWeight: FontWeight.w800),
          decoration: const InputDecoration(hintText: '••••••'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _venueId != null && _otp.text.length == 6 && !widget.busy
              ? () => widget.onSubmit(_venueId!, _otp.text)
              : null,
          child: widget.busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
              : const Text('Check in'),
        ),
      ],
    );
  }
}

/// Bottom-sheet venue search used by OTP check-in and the buddy planner.
Future<VenueSummary?> pickVenue(BuildContext context) {
  return showModalBottomSheet<VenueSummary>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _VenuePickerSheet(),
  );
}

class _VenuePickerSheet extends StatefulWidget {
  const _VenuePickerSheet();

  @override
  State<_VenuePickerSheet> createState() => _VenuePickerSheetState();
}

class _VenuePickerSheetState extends State<_VenuePickerSheet> {
  String _q = '';
  late Future<List<VenueSummary>> _future = _load();

  Future<List<VenueSummary>> _load() => context.read<Session>().api.venues(q: _q, limit: 30);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search venue', prefixIcon: Icon(Icons.search)),
              onChanged: (v) => setState(() {
                _q = v.trim();
                _future = _load();
              }),
            ),
          ),
          Expanded(
            child: AsyncView<List<VenueSummary>>(
              future: _future,
              builder: (context, venues) => ListView.builder(
                itemCount: venues.length,
                itemBuilder: (_, i) => ListTile(
                  leading: const Icon(Icons.storefront_outlined),
                  title: Text(venues[i].name),
                  subtitle: Text(venues[i].location),
                  onTap: () => Navigator.pop(context, venues[i]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class CheckinSuccessScreen extends StatelessWidget {
  const CheckinSuccessScreen({super.key, required this.checkin});

  final Checkin checkin;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Spacer(),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.4, end: 1),
              duration: const Duration(milliseconds: 600),
              curve: Curves.elasticOut,
              builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: const BoxDecoration(color: FkColors.lime, shape: BoxShape.circle),
                child: const Icon(Icons.check, size: 64, color: Colors.black),
              ),
            ),
            const SizedBox(height: 28),
            Text('You\'re checked in!', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(checkin.venueName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            if (checkin.venueArea != null)
              Text(checkin.venueArea!, style: const TextStyle(color: FkColors.textSecondary)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: FkColors.surface, borderRadius: BorderRadius.circular(14)),
              child: Text(
                '${formatDateTime(checkin.checkedInAt)} · ${checkin.planName ?? 'FITKEY'}',
                style: const TextStyle(color: FkColors.textSecondary),
              ),
            ),
            const SizedBox(height: 12),
            const Text('+10 leaderboard points', style: TextStyle(color: FkColors.lime, fontWeight: FontWeight.w700)),
            const Spacer(),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ]),
        ),
      ),
    );
  }
}
