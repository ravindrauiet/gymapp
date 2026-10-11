import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/models.dart';
import '../../state/partner_session.dart';

/// P6 — front-desk screen. Shows a rotating QR (members scan it in the FITKEY app) and a 6-digit OTP fallback.
/// Codes expire after 5 minutes and refresh automatically; the live feed shows members as they check in.
class CheckinCodeScreen extends StatefulWidget {
  const CheckinCodeScreen({super.key, required this.venueId, required this.venueName});

  final String venueId;
  final String venueName;

  @override
  State<CheckinCodeScreen> createState() => _CheckinCodeScreenState();
}

class _CheckinCodeScreenState extends State<CheckinCodeScreen> {
  CheckinCode? _code;
  String? _error;
  List<AttendanceEntry> _today = const [];
  Timer? _tick;
  Timer? _feed;
  Duration _left = Duration.zero;
  bool _refreshing = false;

  static const _refreshBefore = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadFeed();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _feed = Timer.periodic(const Duration(seconds: 8), (_) => _loadFeed());
  }

  void _onTick() {
    final code = _code;
    if (code == null) return;
    final left = code.expiresAt.difference(DateTime.now());
    setState(() => _left = left.isNegative ? Duration.zero : left);
    if (left <= _refreshBefore && !_refreshing) _refresh();
  }

  Future<void> _refresh() async {
    _refreshing = true;
    try {
      final code = await context.read<PartnerSession>().api.checkinCode(widget.venueId);
      if (!mounted) return;
      setState(() {
        _code = code;
        _error = null;
        _left = code.expiresAt.difference(DateTime.now());
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _loadFeed() async {
    try {
      final list = await context.read<PartnerSession>().api.attendance(widget.venueId);
      if (!mounted) return;
      final isNew = list.isNotEmpty && (_today.isEmpty || list.first.id != _today.first.id);
      final hadData = _today.isNotEmpty;
      setState(() => _today = list);
      if (isNew && hadData) {
        showSnack(context, '✅ ${list.first.memberName ?? 'Member'} just checked in');
      }
    } catch (_) {
      // Feed is best-effort; the QR keeps working.
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _feed?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final totalSeconds = 300;
    final mm = _left.inMinutes.toString().padLeft(2, '0');
    final ss = (_left.inSeconds % 60).toString().padLeft(2, '0');

    return Scaffold(
      appBar: AppBar(title: Text(widget.venueName)),
      body: _error != null && code == null
          ? ErrorState(message: _error!, onRetry: _refresh)
          : code == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                  children: [
                    const Text('Scan to check in',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    const Text('Open the FITKEY app → Check in → point the camera here',
                        textAlign: TextAlign.center, style: TextStyle(color: FkColors.textSecondary)),
                    const SizedBox(height: 20),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: QrImageView(
                            key: ValueKey(code.qr),
                            data: code.qr,
                            size: 260,
                            backgroundColor: Colors.white,
                            errorCorrectionLevel: QrErrorCorrectLevel.M,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (_left.inSeconds / totalSeconds).clamp(0, 1),
                        minHeight: 5,
                        backgroundColor: FkColors.surfaceHigh,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text('New code in $mm:$ss',
                        textAlign: TextAlign.center, style: const TextStyle(color: FkColors.textSecondary, fontSize: 12)),
                    const SizedBox(height: 24),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(children: [
                          const Text('Camera not working? Share this code',
                              style: TextStyle(color: FkColors.textSecondary)),
                          const SizedBox(height: 8),
                          Text(
                            '${code.otp.substring(0, 3)} ${code.otp.substring(3)}',
                            style: const TextStyle(
                                fontSize: 40, fontWeight: FontWeight.w900, letterSpacing: 6, color: FkColors.lime),
                          ),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh code now'),
                      onPressed: _refreshing ? null : _refresh,
                    ),
                    SectionHeader('Checked in today (${_today.length})'),
                    if (_today.isEmpty)
                      const Text('No check-ins yet today.', style: TextStyle(color: FkColors.textSecondary))
                    else
                      ..._today.take(10).map((c) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Avatar(name: c.memberName, radius: 18),
                            title: Text(c.memberName ?? 'FITKEY member'),
                            subtitle: Text('•••• ${c.phoneLast4 ?? ''} · ${c.planName ?? ''}'),
                            trailing: Text(formatClock(c.checkedInAt),
                                style: const TextStyle(color: FkColors.textSecondary)),
                          )),
                  ],
                ),
    );
  }
}
