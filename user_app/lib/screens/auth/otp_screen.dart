import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../state/session.dart';

class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key, required this.phone, this.devOtp});

  final String phone;

  /// Returned by the backend in development (no SMS provider yet).
  final String? devOtp;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _otp = TextEditingController();
  bool _verifying = false;
  String? _devOtp;
  int _resendIn = 30;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _devOtp = widget.devOtp;
    _startTimer();
  }

  void _startTimer() {
    _resendIn = 30;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_resendIn <= 1) t.cancel();
      setState(() => _resendIn--);
    });
  }

  Future<void> _verify() async {
    if (_otp.text.length != 6 || _verifying) return;
    setState(() => _verifying = true);
    try {
      await context.read<Session>().verifyOtp(widget.phone, _otp.text);
      // The session gate swaps the root screen; clear this pushed route.
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) {
        showSnack(context, errorMessage(e), error: true);
        setState(() => _verifying = false);
      }
    }
  }

  Future<void> _resend() async {
    try {
      final devOtp = await context.read<Session>().requestOtp(widget.phone);
      if (!mounted) return;
      setState(() => _devOtp = devOtp);
      _startTimer();
      showSnack(context, 'A new OTP has been sent');
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _otp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            Text('Verify your number', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text('Enter the 6-digit code sent to ${widget.phone}',
                style: const TextStyle(color: FkColors.textSecondary, fontSize: 15)),
            const SizedBox(height: 28),
            TextField(
              controller: _otp,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              style: const TextStyle(fontSize: 28, letterSpacing: 14, fontWeight: FontWeight.w800),
              decoration: const InputDecoration(hintText: '••••••', counterText: ''),
              onChanged: (v) {
                setState(() {});
                if (v.length == 6) _verify();
              },
            ),
            if (_devOtp != null) ...[
              const SizedBox(height: 12),
              Center(
                child: ActionChip(
                  avatar: const Icon(Icons.developer_mode, size: 16),
                  label: Text('Dev OTP: $_devOtp — tap to fill'),
                  onPressed: () {
                    _otp.text = _devOtp!;
                    _verify();
                  },
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _otp.text.length == 6 && !_verifying ? _verify : null,
              child: _verifying
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('Verify & continue'),
            ),
            const SizedBox(height: 12),
            Center(
              child: TextButton(
                onPressed: _resendIn > 0 ? null : _resend,
                child: Text(_resendIn > 0 ? 'Resend OTP in ${_resendIn}s' : 'Resend OTP'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
