// First login of a partner whose listing was created by FitKey (Partner BRD §8): see who listed it, the
// commission plan + payout rule, confirm the payout bank account, then accept the agreement with your own OTP.
// Pops with true once every pending listing is accepted.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/brd_api.dart';
import '../../ui/ui.dart';
import '../../widgets/agreement_sheet.dart';
import '../../widgets/commission_plan_card.dart';
import '../../widgets/listing/documents_bank_step.dart';

class AssistedHandoverScreen extends StatefulWidget {
  const AssistedHandoverScreen({super.key, required this.items});
  final List<PendingAcceptance> items;

  @override
  State<AssistedHandoverScreen> createState() => _AssistedHandoverScreenState();
}

class _AssistedHandoverScreenState extends State<AssistedHandoverScreen> {
  final Set<String> _accepted = {};
  bool _bankOk = false;
  bool _bankConfirmed = false;

  String _key(PendingAcceptance i) => '${i.entityType}:${i.entityId}';

  bool get _allDone => widget.items.every((i) => _accepted.contains(_key(i)));

  Future<void> _accept(PendingAcceptance item) async {
    if (!_bankOk || !_bankConfirmed) {
      toast(context, 'Confirm your payout bank account first', error: true);
      return;
    }
    final ok = await showAgreementSheet(context, entityType: item.entityType, entityId: item.entityId);
    if (!ok || !mounted) return;
    HapticFeedback.heavyImpact();
    setState(() => _accepted.add(_key(item)));
    if (_allDone) {
      toast(context, 'You\'re all set — your listing goes live now', icon: Icons.celebration_rounded);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.of(context).pop(true);
    } else {
      toast(context, '${item.name} accepted', icon: Icons.verified_user_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = widget.items.isEmpty ? null : widget.items.first;
    final by = first?.listedByName ?? 'the FitKey team';
    final title = widget.items.length == 1 ? first!.name : '${widget.items.length} listings';
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: Container(
            decoration: const BoxDecoration(
              gradient: AppColors.passGradient,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 26),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Later', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const Tag('WELCOME TO FITKEY', solid: true, color: AppColors.lime, dense: true),
                  const SizedBox(height: 14),
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: title, style: const TextStyle(color: AppColors.lime)),
                      TextSpan(text: widget.items.length == 1 ? ' was listed for you by ' : ' were listed for you by '),
                      TextSpan(text: by, style: const TextStyle(color: AppColors.lime)),
                    ]),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, height: 1.25, letterSpacing: -0.5),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'It has been approved by our team. Check the plan, confirm where we pay you, and accept with an OTP to go live.',
                    style: TextStyle(color: Colors.white70, height: 1.45),
                  ),
                ]),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
          sliver: SliverList.list(children: [
            const _StepLabel(n: 1, text: 'Your commission plan'),
            const CommissionPlanCard(showPayoutRule: true),
            const SizedBox(height: 22),
            const _StepLabel(n: 2, text: 'Confirm your payout account'),
            BankAccountCard(onChanged: (ok) {
              if (mounted) setState(() => _bankOk = ok);
            }),
            if (_bankOk)
              CheckboxListTile(
                value: _bankConfirmed,
                onChanged: (v) => setState(() => _bankConfirmed = v == true),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('These are my bank details — pay me here.',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              ),
            const SizedBox(height: 22),
            const _StepLabel(n: 3, text: 'Accept the agreement with OTP'),
            for (final item in widget.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ItemCard(
                  item: item,
                  accepted: _accepted.contains(_key(item)),
                  enabled: _bankOk && _bankConfirmed,
                  onAccept: () => _accept(item),
                ),
              ),
            const SizedBox(height: 8),
            const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.lock_rounded, size: 16, color: AppColors.text3),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'The FitKey employee who listed you never sees your earnings, members or bank details, and their access ends when you go live.',
                  style: TextStyle(color: AppColors.text3, fontSize: 12.5, height: 1.4),
                ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _StepLabel extends StatelessWidget {
  const _StepLabel({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
            child: Text('$n', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
          ),
          const SizedBox(width: 10),
          Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
        ]),
      );
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item, required this.accepted, required this.enabled, required this.onAccept});
  final PendingAcceptance item;
  final bool accepted;
  final bool enabled;
  final VoidCallback onAccept;

  static const _icons = {
    'venue': Icons.fitness_center_rounded,
    'trainer': Icons.sports_gymnastics_rounded,
    'clinic': Icons.local_hospital_rounded,
    'chemist': Icons.local_pharmacy_rounded,
    'store': Icons.storefront_rounded,
  };

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            IconBubble(_icons[item.entityType] ?? Icons.storefront_rounded,
                color: accepted ? AppColors.green : AppColors.purple, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                Text(
                  accepted
                      ? 'Accepted — going live'
                      : 'Approved · listed by ${item.listedByName ?? 'FitKey'}',
                  style: TextStyle(
                    color: accepted ? AppColors.green : AppColors.text2,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ]),
            ),
            if (accepted) const Icon(Icons.check_circle_rounded, color: AppColors.green),
          ]),
          if (!accepted) ...[
            const SizedBox(height: 12),
            AppButton(
              label: 'Review & accept by OTP',
              icon: Icons.verified_user_rounded,
              onPressed: enabled ? onAccept : null,
            ),
          ],
        ]),
      );
}
