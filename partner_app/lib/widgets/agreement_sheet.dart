import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/brd_api.dart';
import '../state/partner_session.dart';
import '../ui/ui.dart';
import 'commission_plan_card.dart';

/// FitKey partner agreement accepted by OTP (BRD §6.3 step 10, §8 assisted handover).
/// Shows the commission plan + payout rule + terms, sends an OTP to the owner's phone and verifies it.
/// Returns true when accepted.
Future<bool> showAgreementSheet(BuildContext context, {required String entityType, required String entityId}) async {
  final ok = await showAppSheet<bool>(
    context,
    builder: (_) => _AgreementSheet(entityType: entityType, entityId: entityId),
  );
  return ok == true;
}

class _AgreementSheet extends StatefulWidget {
  const _AgreementSheet({required this.entityType, required this.entityId});
  final String entityType;
  final String entityId;

  @override
  State<_AgreementSheet> createState() => _AgreementSheetState();
}

class _AgreementSheetState extends State<_AgreementSheet> {
  final _otp = TextEditingController();
  bool _agree = false;
  bool _sent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _otp.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dev = await context.read<PartnerSession>().api.requestAgreementOtp(widget.entityType, widget.entityId);
      if (!mounted) return;
      setState(() => _sent = true);
      if (dev != null) {
        _otp.text = dev;
        toast(context, 'Dev OTP filled in: $dev');
      } else {
        toast(context, 'OTP sent to your registered mobile number', icon: Icons.sms_rounded);
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() async {
    if (_otp.text.trim().length < 4) {
      setState(() => _error = 'Enter the OTP sent to your phone');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<PartnerSession>().api.acceptAgreement(widget.entityType, widget.entityId, _otp.text.trim());
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          const Text('FitKey partner agreement', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          const SizedBox(height: 6),
          const Text('Read the commission plan and payout rule, then confirm with the OTP sent to your phone.',
              style: TextStyle(color: AppColors.text2, height: 1.4)),
          const SizedBox(height: 16),
          const CommissionPlanCard(showPayoutRule: true),
          const SizedBox(height: 14),
          const _Terms(),
          const SizedBox(height: 10),
          CheckboxListTile(
            value: _agree,
            onChanged: (v) => setState(() => _agree = v == true),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('I have read and accept the FitKey partner agreement, commission plan and payout rule.',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
          ),
          if (_sent) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _otp,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'OTP', prefixIcon: Icon(Icons.password_rounded), counterText: ''),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 16),
          AppButton(
            label: _sent ? 'Accept agreement' : 'Send OTP',
            icon: _sent ? Icons.verified_user_rounded : Icons.sms_rounded,
            busy: _busy,
            onPressed: !_agree ? null : (_sent ? _accept : _send),
          ),
          if (_sent)
            TextButton(onPressed: _busy ? null : _send, child: const Text('Resend OTP')),
        ],
      ),
    );
  }
}

class _Terms extends StatelessWidget {
  const _Terms();

  @override
  Widget build(BuildContext context) {
    const points = [
      'You list your venue / services with accurate details, prices and timings, and keep them up to date.',
      'Prices you enter include GST (5%). On sales of your own plans, the GST part (price × 5/105) is deducted from your payout; FitKey files and pays it for you.',
      'FitKey pass users are served at the hours you allow. Each FitKey pass check-in is paid at your monthly fee ÷ 30 minus that year\'s commission; FitKey bears the GST on these visits.',
      'Payouts are made only to your verified bank account, on the published schedule, with a statement and GST invoice.',
      'FitKey may pause a listing that breaks the Partner Policy (fake details, unsafe premises, repeated member complaints).',
    ];
    return AppCard(
      shadow: false,
      border: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Key terms', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        for (final p in points)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('•  ', style: TextStyle(color: AppColors.text2)),
              Expanded(child: Text(p, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.4))),
            ]),
          ),
      ]),
    );
  }
}
