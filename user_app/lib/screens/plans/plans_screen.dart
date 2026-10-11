import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import '../explore/venue_detail_screen.dart';

/// U2 — browse and buy subscription plans, and see which venues each covers.
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key});

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  late Future<List<Plan>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<Session>().api.plans();
  }

  Future<void> _buy(Plan plan) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (_) => _CheckoutSheet(plan: plan),
    );
    if (confirmed != true || !mounted) return;
    final session = context.read<Session>();
    try {
      await session.api.buyPlan(plan.id);
      await session.refresh();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.key, color: FkColors.lime, size: 40),
          title: const Text('You\'re in! 🎉'),
          content: Text('${plan.name} is active. Scan the QR at any covered venue to check in.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Let\'s go'))],
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = context.watch<Session>().subscription;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plans'),
        actions: [
          TextButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MySubscriptionsScreen())),
            child: const Text('My plans'),
          ),
        ],
      ),
      body: AsyncView<List<Plan>>(
        future: _future,
        onRetry: () => setState(() => _future = context.read<Session>().api.plans()),
        builder: (context, plans) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            const Text('One key. Every workout.', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text('Choose what you love — switch anytime.', style: TextStyle(color: FkColors.textSecondary)),
            const SizedBox(height: 20),
            for (final plan in plans) ...[
              _PlanCard(
                plan: plan,
                highlighted: plan.code.startsWith('all_access'),
                isCurrent: active?.planId == plan.id,
                onBuy: () => _buy(plan),
              ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.highlighted, required this.isCurrent, required this.onBuy});

  final Plan plan;
  final bool highlighted;
  final bool isCurrent;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: FkColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: highlighted ? FkColors.lime : FkColors.outline, width: highlighted ? 2 : 1),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(plan.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
            if (highlighted)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: FkColors.lime, borderRadius: BorderRadius.circular(20)),
                child: const Text('BEST VALUE',
                    style: TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w800)),
              ),
          ]),
          if (plan.description != null) ...[
            const SizedBox(height: 4),
            Text(plan.description!, style: const TextStyle(color: FkColors.textSecondary)),
          ],
          const SizedBox(height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(formatPaise(plan.pricePaise), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900)),
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4),
              child: Text('/ ${plan.durationDays} days', style: const TextStyle(color: FkColors.textSecondary)),
            ),
          ]),
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: plan.categories.map((c) => CategoryPill(venueCategory(c), dense: true)).toList(),
          ),
          const SizedBox(height: 14),
          ...plan.features.map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  const Icon(Icons.check, size: 18, color: FkColors.lime),
                  const SizedBox(width: 8),
                  Expanded(child: Text(f)),
                ]),
              )),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlanVenuesScreen(plan: plan))),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                const Icon(Icons.place_outlined, size: 18, color: FkColors.sky),
                const SizedBox(width: 8),
                Text('${plan.venueCount} partner venues',
                    style: const TextStyle(color: FkColors.sky, fontWeight: FontWeight.w600)),
                const Icon(Icons.chevron_right, color: FkColors.sky, size: 18),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: onBuy,
            style: highlighted
                ? null
                : FilledButton.styleFrom(backgroundColor: FkColors.surfaceHigh, foregroundColor: FkColors.textPrimary),
            child: Text(isCurrent ? 'Renew' : 'Get ${plan.name}'),
          ),
        ],
      ),
    );
  }
}

class _CheckoutSheet extends StatelessWidget {
  const _CheckoutSheet({required this.plan});

  final Plan plan;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Confirm purchase', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 20),
            _row('Plan', plan.name),
            _row('Validity', '${plan.durationDays} days'),
            const Divider(height: 28),
            _row('Total', formatPaise(plan.pricePaise), bold: true),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: FkColors.surfaceHigh, borderRadius: BorderRadius.circular(12)),
              child: const Row(children: [
                Icon(Icons.info_outline, size: 18, color: FkColors.textSecondary),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Test mode: payment gateway not connected yet — the plan activates instantly.',
                      style: TextStyle(fontSize: 12, color: FkColors.textSecondary)),
                ),
              ]),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Pay ${formatPaise(plan.pricePaise)}')),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(label, style: const TextStyle(color: FkColors.textSecondary)),
          const Spacer(),
          Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontSize: bold ? 18 : 15)),
        ]),
      );
}

class PlanVenuesScreen extends StatelessWidget {
  const PlanVenuesScreen({super.key, required this.plan});

  final Plan plan;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${plan.name} venues')),
      body: AsyncView<List<VenueSummary>>(
        future: context.read<Session>().api.planVenues(plan.id),
        builder: (context, venues) => venues.isEmpty
            ? const EmptyState(icon: Icons.place_outlined, title: 'No venues yet', message: 'Partners are being onboarded.')
            : ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: venues.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final v = venues[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    leading: SizedBox(
                      width: 56,
                      height: 56,
                      child: VenueImage(
                          url: v.coverPhoto, category: v.categories.firstOrNull, height: 56, borderRadius: 12),
                    ),
                    title: Text(v.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(v.location),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        Navigator.push(context, MaterialPageRoute(builder: (_) => VenueDetailScreen(venueId: v.id))),
                  );
                },
              ),
      ),
    );
  }
}

class MySubscriptionsScreen extends StatelessWidget {
  const MySubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My plans')),
      body: AsyncView<List<Subscription>>(
        future: context.read<Session>().api.mySubscriptions(),
        builder: (context, subs) => subs.isEmpty
            ? const EmptyState(icon: Icons.card_membership, title: 'No plans yet', message: 'Your purchases will show here.')
            : ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: subs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, i) {
                  final s = subs[i];
                  final color = switch (s.state) {
                    'active' => FkColors.lime,
                    'upcoming' => FkColors.sky,
                    _ => FkColors.textSecondary,
                  };
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(s.planName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            Text('${formatDate(s.startsAt)} → ${formatDate(s.endsAt)}',
                                style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
                            Text('Paid ${formatPaise(s.amountPaise)}',
                                style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
                          ]),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
                          child: Text(s.state.toUpperCase(),
                              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
                        ),
                      ]),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
