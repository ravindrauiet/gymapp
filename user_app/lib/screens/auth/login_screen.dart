import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../state/session.dart';
import 'otp_screen.dart';

/// U1 — sign up / log in with phone number.
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
    setState(() => _sending = true);
    final phone = '+91${_phone.text}';
    try {
      final devOtp = await context.read<Session>().requestOtp(phone);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => OtpScreen(phone: phone, devOtp: devOtp)));
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
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
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 32),
                    const FitKeyLogo(size: 44),
                    const Spacer(),
                    Text('Your Key to\nFitness Everywhere.', style: textTheme.headlineLarge),
                    const SizedBox(height: 12),
                    const Text(
                      'One membership for gyms, pools, sports clubs, yoga, dance and martial-arts centres near you.',
                      style: TextStyle(color: FkColors.textSecondary, fontSize: 15, height: 1.4),
                    ),
                    const SizedBox(height: 20),
                    const Wrap(spacing: 8, runSpacing: 8, children: [
                      _Badge(Icons.fitness_center, 'Gyms'),
                      _Badge(Icons.pool, 'Pools'),
                      _Badge(Icons.sports_tennis, 'Sports'),
                      _Badge(Icons.self_improvement, 'Yoga'),
                      _Badge(Icons.sports_mma, 'Combat'),
                    ]),
                    const SizedBox(height: 36),
                    Text('Enter your mobile number', style: textTheme.titleMedium),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      autofillHints: const [AutofillHints.telephoneNumberNational],
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
                      onSubmitted: (_) => _valid ? _sendOtp() : null,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _valid && !_sending ? _sendOtp : null,
                      child: _sending
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : const Text('Get OTP'),
                    ),
                    const SizedBox(height: 16),
                    const Center(
                      child: Text(
                        'By continuing you agree to FITKEY\'s Terms & Privacy Policy',
                        style: TextStyle(fontSize: 12, color: FkColors.textSecondary),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: FkColors.surface,
        border: Border.all(color: FkColors.outline),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: FkColors.lime),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
