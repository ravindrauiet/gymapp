import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../../widgets/brand.dart';

/// P1 — venue owner / vendor / trainer signs up or logs in with phone OTP.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  bool _sending = false;

  bool get _valid => _phone.text.length == 10;

  Future<void> _sendOtp() async {
    if (!_valid || _sending) return;
    FocusScope.of(context).unfocus();
    setState(() => _sending = true);
    final phone = '+91${_phone.text}';
    try {
      final devOtp = await context.read<PartnerSession>().requestOtp(phone);
      if (!mounted) return;
      setState(() => _sending = false);
      await push(context, _OtpScreen(phone: phone, devOtp: devOtp));
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted && _sending) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.surface,
        body: SingleChildScrollView(
          child: Column(children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.52,
              child: Stack(fit: StackFit.expand, children: [
                Image.asset(AppImages.gymFloor, fit: BoxFit.cover, alignment: const Alignment(0, -0.2)),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x991A1B25), Color(0x661A1B25), Color(0xF51A1B25)],
                      stops: [0, 0.3, 0.75],
                    ),
                  ),
                ),
                Positioned(top: top + 16, left: 20, child: const PartnerLockup(size: 32, light: true)),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 52,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Grow your\nfitness business',
                        style: TextStyle(
                            color: Colors.white, fontSize: 36, fontWeight: FontWeight.w800, height: 1.05, letterSpacing: -1.2)),
                    const SizedBox(height: 10),
                    const Text(
                        'List your gym, pool, studio or club, sell on the FITKEY store, coach members — and track every check-in.',
                        style: TextStyle(color: Colors.white70, fontSize: 14.5, height: 1.4, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 14),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final c in const ['gym', 'swimming_pool', 'yoga_studio', 'sports_club', 'mma', 'dance'])
                        _HeroChip(venueVisual(c)),
                    ]),
                  ]),
                ),
              ]),
            ),
            Container(
              width: double.infinity,
              transform: Matrix4.translationValues(0, -28, 0),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: EdgeInsets.fromLTRB(20, 26, 20, 20 + MediaQuery.paddingOf(context).bottom),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const DividerTitle('Partner log in or sign up', padding: EdgeInsets.only(bottom: 22)),
                Container(
                  height: 58,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.line, width: 1.4),
                  ),
                  child: Row(children: [
                    const SizedBox(width: 14),
                    const Text('🇮🇳', style: TextStyle(fontSize: 20)),
                    const SizedBox(width: 6),
                    const Text('+91', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    Container(width: 1, height: 26, color: AppColors.line, margin: const EdgeInsets.symmetric(horizontal: 12)),
                    Expanded(
                      child: TextField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        autofillHints: const [AutofillHints.telephoneNumberNational],
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
                        style: const TextStyle(fontSize: 18, letterSpacing: 1.5, fontWeight: FontWeight.w700),
                        decoration: const InputDecoration(
                          hintText: 'Owner mobile number',
                          hintStyle: TextStyle(letterSpacing: 0, fontSize: 16, color: AppColors.text3),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _sendOtp(),
                      ),
                    ),
                    if (_valid)
                      const Padding(
                        padding: EdgeInsets.only(right: 14),
                        child: Icon(Icons.check_circle_rounded, color: AppColors.green),
                      ),
                  ]),
                ),
                const SizedBox(height: 16),
                AppButton(label: 'Get OTP', busy: _sending, onPressed: _valid ? _sendOtp : null),
                const SizedBox(height: 22),
                const Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _Perk(Icons.storefront_rounded, 'List in minutes'),
                  _Perk(Icons.qr_code_2_rounded, 'Instant check-ins'),
                  _Perk(Icons.insights_rounded, 'Daily attendance'),
                ]),
                const SizedBox(height: 18),
                const Text(
                  'By continuing, you agree to the FITKEY Partner Terms & Privacy Policy',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: AppColors.text3),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip(this.v);
  final CatVisual v;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(v.icon, size: 14, color: Colors.white),
        const SizedBox(width: 5),
        Text(v.label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _Perk extends StatelessWidget {
  const _Perk(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      IconBubble(icon, size: 40),
      const SizedBox(height: 6),
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.text2)),
    ]);
  }
}

// ---------------------------------------------------------------------------
// OTP verification
// ---------------------------------------------------------------------------

class _OtpScreen extends StatefulWidget {
  const _OtpScreen({required this.phone, this.devOtp});

  final String phone;

  /// Returned by the backend in development (no SMS provider yet).
  final String? devOtp;

  @override
  State<_OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<_OtpScreen> {
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
      await context.read<PartnerSession>().verifyOtp(widget.phone, _otp.text);
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
      final devOtp = await context.read<PartnerSession>().requestOtp(widget.phone);
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
        const Text('Verify your number', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
        const SizedBox(height: 6),
        Text.rich(TextSpan(
          style: const TextStyle(color: AppColors.text2, fontSize: 15, height: 1.4),
          children: [
            const TextSpan(text: 'We\'ve sent a 6-digit code to '),
            TextSpan(text: _prettyPhone, style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.text)),
            const TextSpan(text: '. '),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Tap(
                onTap: () => Navigator.pop(context),
                child: const Text('Change',
                    style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 15)),
              ),
            ),
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
                setState(() {});
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
                    child: Text(filled ? text[i] : '', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
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
