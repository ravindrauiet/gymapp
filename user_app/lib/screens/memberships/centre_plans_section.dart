import 'package:fitkey_core/fitkey_core.dart' show formatPaise;
import 'package:flutter/material.dart';

import '../../data/booking_api.dart';
import '../../ui/ui.dart';
import 'buy_membership_screen.dart';

/// A centre's own membership plans (BRD §2), shown on the centre page to everyone.
class CentrePlansSection extends StatelessWidget {
  const CentrePlansSection({super.key, required this.plans, required this.venueName, this.primary = false, this.onSelect});

  final List<CentrePlan> plans;
  final String venueName;

  /// True when the member has no FitKey pass: the plans are the main way in, so they're shown first & larger.
  final bool primary;

  /// Defaults to opening [BuyMembershipScreen].
  final ValueChanged<CentrePlan>? onSelect;

  @override
  Widget build(BuildContext context) {
    if (plans.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('$venueName memberships',
          subtitle: primary ? 'Buy directly from this centre — valid only here' : 'Valid only at this centre'),
      for (final p in plans)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: CentrePlanCard(
            plan: p,
            onTap: () => onSelect != null ? onSelect!(p) : push(context, BuyMembershipScreen(plan: p, venueName: venueName)),
          ),
        ),
    ]);
  }
}

class CentrePlanCard extends StatelessWidget {
  const CentrePlanCard({super.key, required this.plan, required this.onTap});
  final CentrePlan plan;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = plan;
    return AppCard(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const IconBubble(Icons.card_membership_rounded, color: AppColors.purple, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
              Text(
                p.duration == 'hourly' ? p.durationLabel : [p.durationLabel, p.validityLabel].join(' · '),
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
              ),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(formatPaise(p.effectivePricePaise) + (p.duration == 'hourly' ? '/hr' : ''),
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16.5)),
            if (p.offerPct > 0)
              Text(formatPaise(p.pricePaise),
                  style: const TextStyle(color: AppColors.text3, decoration: TextDecoration.lineThrough, fontSize: 12)),
          ]),
        ]),
        if (p.offerPct > 0) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Tag('${p.offerPct}% off', color: AppColors.green, icon: Icons.local_offer_rounded, dense: true),
          ),
        ],
        if (p.inclusions.isNotEmpty || p.limitsLabel != null) ...[
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 8),
          if (p.inclusions.isNotEmpty) ...[
            const Text("WHAT'S INCLUDED",
                style: TextStyle(fontSize: 10.5, letterSpacing: 1.1, fontWeight: FontWeight.w800, color: AppColors.text3)),
            const SizedBox(height: 4),
            for (final i in p.inclusions.take(5)) _Line(Icons.check_circle_rounded, AppColors.green, i),
            if (p.inclusions.length > 5)
              Text('+${p.inclusions.length - 5} more',
                  style: const TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
          if (p.limitsLabel != null) _Line(Icons.event_repeat_rounded, AppColors.blue, 'Slot limit: ${p.limitsLabel}'),
        ],
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.color, this.text);
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.35))),
      ]),
    );
  }
}
