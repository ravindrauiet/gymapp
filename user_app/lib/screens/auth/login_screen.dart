import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/session.dart';
import '../../ui/ui.dart';
import '../../widgets/brand.dart';
import 'otp_screen.dart';

/// U1 — sign up / log in with a phone number.
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
      final devOtp = await context.read<Session>().requestOtp(phone);
      if (!mounted) return;
      await push(context, OtpScreen(phone: phone, devOtp: devOtp));
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
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
        // White so the login panel always reaches the bottom edge on tall screens.
        backgroundColor: AppColors.surface,
        body: SingleChildScrollView(
          child: Column(children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.5,
              child: Stack(fit: StackFit.expand, children: [
                Image.asset(AppImages.onboarding, fit: BoxFit.cover, alignment: const Alignment(0, -0.3)),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x661A1B25), Color(0x001A1B25), Color(0xF21A1B25)],
                      stops: [0, 0.35, 1],
                    ),
                  ),
                ),
                Positioned(top: top + 16, left: 20, child: const BrandLockup(size: 34, light: true)),
                const Positioned(
                  left: 20,
                  right: 20,
                  bottom: 54,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('One pass.\nEvery workout.',
                        style: TextStyle(
                            color: Colors.white, fontSize: 36, fontWeight: FontWeight.w800, height: 1.05, letterSpacing: -1.2)),
                    SizedBox(height: 10),
                    Text('Gyms, pools, yoga, sports, MMA & dance — all with a single FitKey Pass.',
                        style: TextStyle(color: Colors.white70, fontSize: 14.5, height: 1.4, fontWeight: FontWeight.w500)),
                  ]),
                ),
              ]),
            ),
            Container(
              width: double.infinity,
              // Slide the panel up over the photo so its rounded corners show.
              transform: Matrix4.translationValues(0, -28, 0),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: EdgeInsets.fromLTRB(20, 26, 20, 20 + MediaQuery.paddingOf(context).bottom),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const DividerTitle('Log in or sign up', padding: EdgeInsets.only(bottom: 22)),
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
                          hintText: 'Enter mobile number',
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
                AppButton(label: 'Continue', busy: _sending, onPressed: _valid ? _sendOtp : null),
                const SizedBox(height: 20),
                const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _Perk(Icons.verified_user_rounded, 'Verified venues'),
                  SizedBox(width: 16),
                  _Perk(Icons.qr_code_2_rounded, 'Scan & walk in'),
                  SizedBox(width: 16),
                  _Perk(Icons.auto_awesome_rounded, 'AI coach'),
                ]),
                const SizedBox(height: 18),
                const Text(
                  'By continuing, you agree to our Terms of Service & Privacy Policy',
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

class _Perk extends StatelessWidget {
  const _Perk(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Icon(icon, size: 20, color: AppColors.primary),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.text2)),
    ]);
  }
}
