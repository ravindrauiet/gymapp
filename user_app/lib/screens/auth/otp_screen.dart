import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/session.dart';
import '../../ui/ui.dart';

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
  final _focus = FocusNode();
  bool _verifying = false;
  bool _wrong = false;
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
      if (!mounted) return t.cancel();
      if (_resendIn <= 1) t.cancel();
      setState(() => _resendIn--);
    });
  }

  Future<void> _verify() async {
    if (_otp.text.length != 6 || _verifying) return;
    setState(() {
      _verifying = true;
      _wrong = false;
    });
    try {
      await context.read<Session>().verifyOtp(widget.phone, _otp.text);
      // The session gate swaps the root screen; clear this pushed route.
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _verifying = false;
        _wrong = true;
      });
      toast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _resend() async {
    try {
      final devOtp = await context.read<Session>().requestOtp(widget.phone);
      if (!mounted) return;
      setState(() {
        _devOtp = devOtp;
        _otp.clear();
        _wrong = false;
      });
      _startTimer();
      toast(context, 'A new OTP has been sent');
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _otp.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _prettyPhone {
    final p = widget.phone;
    return p.length == 13 ? '${p.substring(0, 3)} ${p.substring(3, 8)} ${p.substring(8)}' : p;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
        const IconBubble(Icons.sms_rounded, size: 56),
        const SizedBox(height: 20),
        const Text('OTP verification', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
        const SizedBox(height: 6),
        Text.rich(TextSpan(
          style: const TextStyle(color: AppColors.text2, fontSize: 15, height: 1.4),
          children: [
            const TextSpan(text: 'We\'ve sent a 6-digit code to '),
            TextSpan(text: _prettyPhone, style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.text)),
          ],
        )),
        const SizedBox(height: 28),
        _OtpBoxes(
          controller: _otp,
          focusNode: _focus,
          error: _wrong,
          onChanged: (v) {
            setState(() => _wrong = false);
            if (v.length == 6) _verify();
          },
        ),
        if (_devOtp != null) ...[
          const SizedBox(height: 16),
          Center(
            child: Tap(
              onTap: () {
                _otp.text = _devOtp!;
                _verify();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(color: AppColors.amberSoft, borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.developer_mode_rounded, size: 16, color: AppColors.amber),
                  const SizedBox(width: 6),
                  Text('Test mode · OTP $_devOtp · tap to fill',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: Color(0xFF9A5B00))),
                ]),
              ),
            ),
          ),
        ],
        const SizedBox(height: 28),
        AppButton(label: 'Verify & continue', busy: _verifying, onPressed: _otp.text.length == 6 ? _verify : null),
        const SizedBox(height: 16),
        Center(
          child: _resendIn > 0
              ? Text.rich(TextSpan(
                  style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600),
                  children: [
                    const TextSpan(text: 'Didn\'t get it? Resend in '),
                    TextSpan(
                        text: '0:${_resendIn.toString().padLeft(2, '0')}',
                        style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w800)),
                  ],
                ))
              : TextButton(onPressed: _resend, child: const Text('Resend OTP')),
        ),
      ]),
    );
  }
}

/// Six individual digit boxes over one hidden text field (keeps paste & SMS autofill working).
class _OtpBoxes extends StatelessWidget {
  const _OtpBoxes({required this.controller, required this.focusNode, required this.onChanged, required this.error});

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Opacity(
        opacity: 0,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: true,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          onChanged: onChanged,
          showCursor: false,
          enableInteractiveSelection: false,
        ),
      ),
      GestureDetector(
        onTap: () => focusNode.requestFocus(),
        child: ListenableBuilder(
          listenable: Listenable.merge([controller, focusNode]),
          builder: (context, _) {
            final text = controller.text;
            return Row(
              children: List.generate(6, (i) {
                final filled = i < text.length;
                final active = focusNode.hasFocus && i == text.length.clamp(0, 5);
                final color = error ? AppColors.red : (active ? AppColors.primary : (filled ? AppColors.ink : AppColors.line));
                return Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: 58,
                    margin: EdgeInsets.only(right: i == 5 ? 0 : 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: filled ? AppColors.surface : AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: color, width: active || error ? 2 : 1.4),
                    ),
                    child: Text(filled ? text[i] : '',
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                  ),
                );
              }),
            );
          },
        ),
      ),
    ]);
  }
}
