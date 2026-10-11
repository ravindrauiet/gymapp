import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/partner_session.dart';

/// P1 — venue owner signs up / logs in with phone OTP.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _otp = TextEditingController();
  bool _otpSent = false;
  bool _busy = false;
  String? _devOtp;
  int _resendIn = 0;
  Timer? _timer;

  String get _fullPhone => '+91${_phone.text}';

  Future<void> _sendOtp() async {
    setState(() => _busy = true);
    try {
      final devOtp = await context.read<PartnerSession>().requestOtp(_fullPhone);
      if (!mounted) return;
      setState(() {
        _otpSent = true;
        _devOtp = devOtp;
        _resendIn = 30;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (_resendIn <= 1) t.cancel();
        if (mounted) setState(() => _resendIn--);
      });
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_otp.text.length != 6 || _busy) return;
    setState(() => _busy = true);
    try {
      await context.read<PartnerSession>().verifyOtp(_fullPhone, _otp.text);
    } catch (e) {
      if (mounted) {
        showSnack(context, errorMessage(e), error: true);
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _otp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            const SizedBox(height: 32),
            const Align(alignment: Alignment.centerLeft, child: FitKeyLogo(size: 40, tag: 'PARTNER')),
            const SizedBox(height: 48),
            Text('Grow your venue\nwith FITKEY', style: text.headlineLarge),
            const SizedBox(height: 12),
            const Text(
              'List your gym, pool, studio or club, welcome FITKEY members, and track every check-in.',
              style: TextStyle(color: FkColors.textSecondary, fontSize: 15, height: 1.4),
            ),
            const SizedBox(height: 28),
            const _Benefit(Icons.storefront, 'List in minutes', 'Photos, timings, facilities — reviewed by our team.'),
            const _Benefit(Icons.qr_code_2, 'Instant check-ins', 'Members scan your QR at the front desk.'),
            const _Benefit(Icons.insights, 'Daily attendance', 'See who visited, by day and by month.'),
            const SizedBox(height: 28),
            Text(_otpSent ? 'Enter the OTP sent to $_fullPhone' : 'Owner mobile number', style: text.titleMedium),
            const SizedBox(height: 12),
            if (!_otpSent)
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
                style: const TextStyle(fontSize: 18, letterSpacing: 1.2, fontWeight: FontWeight.w600),
                decoration: const InputDecoration(
                  hintText: '98765 43210',
                  prefixIcon: Padding(
                    padding: EdgeInsets.only(left: 16, right: 8),
                    child: Text('+91', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  ),
                  prefixIconConstraints: BoxConstraints(minWidth: 0, minHeight: 0),
                ),
                onChanged: (_) => setState(() {}),
              )
            else ...[
              TextField(
                controller: _otp,
                autofocus: true,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                style: const TextStyle(fontSize: 26, letterSpacing: 12, fontWeight: FontWeight.w800),
                decoration: const InputDecoration(hintText: '••••••'),
                onChanged: (v) {
                  setState(() {});
                  if (v.length == 6) _verify();
                },
              ),
              if (_devOtp != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Center(
                    child: ActionChip(
                      avatar: const Icon(Icons.developer_mode, size: 16),
                      label: Text('Dev OTP: $_devOtp — tap to fill'),
                      onPressed: () {
                        _otp.text = _devOtp!;
                        _verify();
                      },
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy
                  ? null
                  : _otpSent
                      ? (_otp.text.length == 6 ? _verify : null)
                      : (_phone.text.length == 10 ? _sendOtp : null),
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Text(_otpSent ? 'Verify & continue' : 'Get OTP'),
            ),
            if (_otpSent)
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                TextButton(
                  onPressed: () => setState(() {
                    _otpSent = false;
                    _otp.clear();
                  }),
                  child: const Text('Change number'),
                ),
                TextButton(
                  onPressed: _resendIn > 0 || _busy ? null : _sendOtp,
                  child: Text(_resendIn > 0 ? 'Resend in ${_resendIn}s' : 'Resend OTP'),
                ),
              ]),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit(this.icon, this.title, this.subtitle);

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: FkColors.lime.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: FkColors.lime, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(subtitle, style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
          ]),
        ),
      ]),
    );
  }
}
