import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/brd_api.dart';
import '../state/partner_session.dart';
import '../ui/ui.dart';

/// "Your commission plan" (BRD §5.3): Year 1 0% → Year 2 2.5% → Year 3+ 5%, with the partner's current year and
/// its end date highlighted. Loads the plan itself unless [plan] is given. [compact] = Home card; full = Account.
class CommissionPlanCard extends StatefulWidget {
  const CommissionPlanCard({super.key, this.plan, this.compact = false, this.showPayoutRule = false});

  final CommissionPlan? plan;
  final bool compact;
  final bool showPayoutRule;

  @override
  State<CommissionPlanCard> createState() => _CommissionPlanCardState();
}

class _CommissionPlanCardState extends State<CommissionPlanCard> {
  CommissionPlan? _plan;

  @override
  void initState() {
    super.initState();
    _plan = widget.plan;
    if (_plan == null) _load();
  }

  Future<void> _load() async {
    try {
      final p = await context.read<PartnerSession>().api.commissionPlan();
      if (mounted) setState(() => _plan = p);
    } catch (_) {
      if (mounted) setState(() => _plan = CommissionPlan.fallback());
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan ?? CommissionPlan.fallback();
    final fmt = DateFormat('d MMM yyyy');
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconBubble(Icons.workspace_premium_rounded, color: AppColors.purple, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Your commission plan', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              Text(
                plan.goLiveAt == null
                    ? 'Founding Partner offer · starts when you go live'
                    : 'Founding Partner · live since ${fmt.format(plan.goLiveAt!)}',
                style: const TextStyle(fontSize: 12.5, color: AppColors.text3, fontWeight: FontWeight.w600),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          for (var i = 0; i < plan.years.length; i++) ...[
            Expanded(child: _yearTile(plan.years[i], fmt)),
            if (i < plan.years.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.arrow_forward_rounded, size: 16, color: AppColors.text3),
              ),
          ],
        ]),
        if (!widget.compact) ...[
          const SizedBox(height: 14),
          Text(plan.message, style: const TextStyle(color: AppColors.text2, height: 1.45, fontSize: 13.5)),
        ],
        if (widget.showPayoutRule) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
            child: Text(plan.payoutRule, style: const TextStyle(color: AppColors.text2, height: 1.45, fontSize: 12.5)),
          ),
        ],
      ]),
    );
  }

  Widget _yearTile(CommissionYear y, DateFormat fmt) {
    final on = y.current;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(
        color: on ? AppColors.purple : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(children: [
        Text(y.pctLabel,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on ? Colors.white : AppColors.text)),
        Text(y.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: on ? Colors.white : AppColors.text2)),
        if (on && y.to != null)
          Text('till ${fmt.format(y.to!)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: Colors.white70, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
