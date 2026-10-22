import 'package:fitkey_core/fitkey_core.dart' show formatDate, formatPaise;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../../widgets/venue_card.dart';
import '../checkin/checkin_screen.dart';
import '../explore/venue_detail_screen.dart';

/// Price per 30 days, for comparing plans of different lengths.
int _monthlyPaise(Plan p) => p.durationDays <= 0 ? p.pricePaise : (p.pricePaise * 30 / p.durationDays).round();

String _validity(int days) => switch (days) {
      30 || 31 => '1 month',
      90 || 91 || 92 => '3 months',
      180 || 182 || 183 => '6 months',
      365 || 366 => '12 months',
      _ => '$days days',
    };

/// U2 — browse and buy FITKEY Pass plans, and see which venues each covers.
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key});

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  late Future<List<Plan>> _future = _load();

  Future<List<Plan>> _load() => context.read<Session>().api.plans();

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f;
  }

  Future<void> _buy(Plan plan) async {
    final active = context.read<Session>().subscription;
    final bought = await showAppSheet<bool>(
      context,
      builder: (_) => _CheckoutSheet(plan: plan, extendsCurrent: active?.planId == plan.id ? active : null),
    );
    if (bought != true || !mounted) return;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (ctx, _, _) => _PurchaseSuccess(plan: plan),
      transitionBuilder: (ctx, a, _, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)), child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = context.watch<Session>().subscription;
    return Scaffold(
      appBar: AppBar(
        title: const Text('FITKEY Pass'),
        actions: [
          TextButton.icon(
            onPressed: () => push(context, const MySubscriptionsScreen()),
            icon: const Icon(Icons.receipt_long_rounded, size: 18),
            label: const Text('My plans'),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _refresh,
        child: FutureBuilder<List<Plan>>(
          future: _future,
          builder: (context, snap) {
            final loading = snap.connectionState != ConnectionState.done;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
              children: [
                _PassHero(active: active),
                const SizedBox(height: 4),
                if (loading)
                  ..._skeleton()
                else if (snap.hasError)
                  ErrorView(error: snap.error!, onRetry: _refresh)
                else if (snap.data!.isEmpty)
                  const EmptyView(
                    icon: Icons.card_membership_rounded,
                    title: 'No plans available right now',
                    message: 'New FITKEY Pass plans are on their way. Pull down to refresh.',
                  )
                else
                  ..._plans(snap.data!, active),
                const SizedBox(height: 8),
                const _Perks(),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _skeleton() => [
        const SectionTitle('Choose your pass'),
        for (var i = 0; i < 2; i++) ...[
          const Shimmer(child: SkeletonBox(height: 360, radius: 22)),
          const SizedBox(height: 16),
        ],
      ];

  List<Widget> _plans(List<Plan> plans, ActiveSubscription? active) {
    // "Best value" = clearly the lowest price per day, only when there is something to compare.
    String? bestValueId;
    if (plans.length > 1) {
      final sorted = [...plans]..sort((a, b) => (a.pricePaise / a.durationDays).compareTo(b.pricePaise / b.durationDays));
      final a = sorted[0], b = sorted[1];
      if (a.pricePaise / a.durationDays < b.pricePaise / b.durationDays) bestValueId = a.id;
    }
    return [
      SectionTitle('Choose your pass', subtitle: '${plans.length} ${plans.length == 1 ? 'plan' : 'plans'} · stack anytime to extend'),
      for (final plan in plans) ...[
        _PlanCard(
          plan: plan,
          bestValue: plan.id == bestValueId,
          isCurrent: active?.planId == plan.id,
          onBuy: () => _buy(plan),
        ),
        const SizedBox(height: 16),
      ],
    ];
  }
}

// ---------------------------------------------------------------------------

class _PassHero extends StatelessWidget {
  const _PassHero({required this.active});
  final ActiveSubscription? active;

  @override
  Widget build(BuildContext context) {
    final sub = active;
    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.passGradient,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [BoxShadow(color: Color(0x331A1B25), blurRadius: 24, offset: Offset(0, 10))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        Positioned(
          right: -50,
          top: -50,
          child: Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.lime.withValues(alpha: 0.08)),
          ),
        ),
        Positioned(
          right: 16,
          bottom: -26,
          child: Icon(Icons.key_rounded, size: 140, color: Colors.white.withValues(alpha: 0.05)),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.key_rounded, color: AppColors.lime, size: 18),
              const SizedBox(width: 6),
              const Text('FITKEY PASS',
                  style: TextStyle(color: AppColors.lime, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 2)),
              const Spacer(),
              if (sub != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: AppColors.green, borderRadius: BorderRadius.circular(20)),
                  child: const Text('ACTIVE',
                      style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800)),
                ),
            ]),
            const SizedBox(height: 14),
            if (sub == null) ...[
              const Text('One key.\nEvery workout.',
                  style: TextStyle(
                      color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, height: 1.1, letterSpacing: -0.8)),
              const SizedBox(height: 8),
              Text('Gyms, pools, studios & courts near you — scan in with a single pass.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13.5, height: 1.4)),
            ] else ...[
              Text(sub.planName,
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
              const SizedBox(height: 4),
              Text(sub.categories.map((c) => venueVisual(c).label).join(' • '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 12.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${sub.daysLeft.clamp(0, 9999)}',
                    style: const TextStyle(color: AppColors.lime, fontSize: 36, fontWeight: FontWeight.w800, height: 1)),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('days left',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontWeight: FontWeight.w700)),
                ),
                const Spacer(),
                Text('Valid till ${formatDate(sub.endsAt)}',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 14),
              Tap(
                onTap: () => push(context, const CheckinScreen()),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: AppColors.lime, borderRadius: BorderRadius.circular(12)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.qr_code_scanner_rounded, size: 18, color: AppColors.ink),
                    SizedBox(width: 6),
                    Text('Check in now', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink)),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.bestValue, required this.isCurrent, required this.onBuy});

  final Plan plan;
  final bool bestValue;
  final bool isCurrent;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    final cats = plan.categories.isEmpty ? ['gym'] : plan.categories;
    final showMonthly = plan.durationDays > 35;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        boxShadow: AppShadows.card,
        border: bestValue ? Border.all(color: AppColors.primary, width: 1.6) : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Category photo strip
        SizedBox(
          height: 110,
          child: Stack(fit: StackFit.expand, children: [
            Row(children: [
              for (var i = 0; i < cats.length && i < 4; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(child: Image.asset(venueVisual(cats[i]).image, fit: BoxFit.cover, height: 110)),
              ],
            ]),
            const PhotoScrim(strength: 0.7),
            Positioned(
              left: 14,
              right: 14,
              bottom: 10,
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final c in cats)
                  Tag(venueVisual(c).label, icon: venueVisual(c).icon, color: AppColors.ink, bg: Colors.white, dense: true),
              ]),
            ),
            Positioned(
              left: 12,
              top: 12,
              child: Row(children: [
                if (bestValue) const Tag('BEST VALUE', color: AppColors.primary, solid: true, icon: Icons.star_rounded, dense: true),
                if (isCurrent) ...[
                  if (bestValue) const SizedBox(width: 6),
                  const Tag('YOUR PLAN', color: AppColors.green, solid: true, icon: Icons.check_circle_rounded, dense: true),
                ],
              ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(plan.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
            if (plan.description != null && plan.description!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(plan.description!, style: const TextStyle(color: AppColors.text2, fontSize: 13.5, height: 1.4)),
            ],
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(formatPaise(plan.pricePaise),
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1)),
              Padding(
                padding: const EdgeInsets.only(bottom: 3, left: 6),
                child: Text('for ${_validity(plan.durationDays)}',
                    style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600)),
              ),
              const Spacer(),
              if (showMonthly)
                Tag('${formatPaise(_monthlyPaise(plan))}/month', color: AppColors.green, dense: true),
            ]),
            if (plan.features.isNotEmpty) ...[
              const SizedBox(height: 16),
              for (final f in plan.features)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      margin: const EdgeInsets.only(top: 1),
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(color: AppColors.greenSoft, shape: BoxShape.circle),
                      child: const Icon(Icons.check_rounded, size: 14, color: AppColors.green),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(f, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500))),
                  ]),
                ),
            ],
            const SizedBox(height: 6),
            Tap(
              onTap: () => push(context, PlanVenuesScreen(plan: plan)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  const Icon(Icons.place_rounded, size: 18, color: AppColors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        plan.venueCount == 0
                            ? 'See partner venues'
                            : '${plan.venueCount} partner ${plan.venueCount == 1 ? 'venue' : 'venues'} included',
                        style: const TextStyle(color: AppColors.blue, fontWeight: FontWeight.w700, fontSize: 13.5)),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.blue, size: 20),
                ]),
              ),
            ),
            const SizedBox(height: 14),
            AppButton(
              label: isCurrent ? 'Extend my plan' : 'Get ${plan.name}',
              icon: isCurrent ? Icons.update_rounded : Icons.key_rounded,
              color: bestValue || isCurrent ? AppColors.primary : AppColors.ink,
              onPressed: onBuy,
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Perks extends StatelessWidget {
  const _Perks();

  @override
  Widget build(BuildContext context) {
    const perks = [
      (Icons.qr_code_scanner_rounded, 'Scan & enter', 'Check in with a QR or desk code', AppColors.primary),
      (Icons.layers_rounded, 'Stack to extend', 'Buy again to add days to your plan', AppColors.purple),
      (Icons.insights_rounded, 'Track progress', 'Every visit counts in your report', AppColors.green),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const DividerTitle('Why FITKEY Pass', padding: EdgeInsets.fromLTRB(0, 16, 0, 16)),
      for (final p in perks)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(children: [
            IconBubble(p.$1, color: p.$4, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.$2, style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(p.$3, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
              ]),
            ),
          ]),
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Checkout
// ---------------------------------------------------------------------------

class _CheckoutSheet extends StatefulWidget {
  const _CheckoutSheet({required this.plan, this.extendsCurrent});

  final Plan plan;

  /// Set when buying the plan the member already has — the new period starts when it ends.
  final ActiveSubscription? extendsCurrent;

  @override
  State<_CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends State<_CheckoutSheet> {
  bool _paying = false;
  String? _error;

  Future<void> _pay() async {
    final session = context.read<Session>();
    setState(() {
      _paying = true;
      _error = null;
    });
    try {
      await session.api.buyPlan(widget.plan.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _paying = false;
        _error = friendlyError(e);
      });
      return;
    }
    try {
      await session.refresh();
    } catch (_) {
      // Purchase succeeded; the pass card will catch up on the next refresh.
    }
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final ext = widget.extendsCurrent;
    final starts = ext?.endsAt ?? DateTime.now();
    final ends = starts.add(Duration(days: plan.durationDays));
    final cat = venueVisual(plan.categories.isEmpty ? 'gym' : plan.categories.first);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Checkout', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(gradient: AppColors.passGradient, borderRadius: BorderRadius.circular(18)),
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(cat.image, width: 58, height: 58, fit: BoxFit.cover),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('FITKEY PASS',
                      style: TextStyle(color: AppColors.lime, fontWeight: FontWeight.w800, fontSize: 10.5, letterSpacing: 1.6)),
                  const SizedBox(height: 2),
                  Text(plan.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                  Text(plan.categories.map((c) => venueVisual(c).label).join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 12)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          _row('Validity', _validity(plan.durationDays)),
          _row(ext != null ? 'Starts after current plan' : 'Starts', formatDate(starts)),
          _row('Valid till', formatDate(ends)),
          if (plan.venueCount > 0) _row('Partner venues', '${plan.venueCount}'),
          const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider()),
          Row(children: [
            const Text('To pay', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const Spacer(),
            Text(formatPaise(plan.pricePaise), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
          ]),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
            child: const Row(children: [
              Icon(Icons.verified_user_rounded, size: 18, color: AppColors.green),
              SizedBox(width: 8),
              Expanded(
                child: Text('Demo payments are enabled — your plan activates instantly and no card is charged.',
                    style: TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w500)),
              ),
            ]),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: AppColors.redSoft, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                const Icon(Icons.error_outline_rounded, color: AppColors.red, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error!,
                      style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w600, fontSize: 13)),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 16),
          AppButton(
            label: 'Pay ${formatPaise(plan.pricePaise)}',
            icon: Icons.lock_rounded,
            busy: _paying,
            onPressed: _pay,
          ),
        ]),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Text(label, style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w500)),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );
}

class _PurchaseSuccess extends StatelessWidget {
  const _PurchaseSuccess({required this.plan});
  final Plan plan;

  @override
  Widget build(BuildContext context) {
    final sub = context.watch<Session>().subscription;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(gradient: AppColors.passGradient, borderRadius: BorderRadius.circular(28)),
            padding: const EdgeInsets.fromLTRB(24, 30, 24, 22),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 700),
                curve: Curves.elasticOut,
                builder: (_, v, child) => Transform.scale(scale: v, child: child),
                child: Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    color: AppColors.lime,
                    shape: BoxShape.circle,
                    boxShadow: AppShadows.glow(AppColors.lime),
                  ),
                  child: const Icon(Icons.key_rounded, size: 46, color: AppColors.ink),
                ),
              ),
              const SizedBox(height: 22),
              const Text("You're in! 🎉",
                  style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
              const SizedBox(height: 8),
              Text(
                '${plan.name} is active${sub != null && sub.planId == plan.id ? ' till ${formatDate(sub.endsAt)}' : ''}.\nScan the QR at any covered venue to check in.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.75), height: 1.45),
              ),
              const SizedBox(height: 24),
              AppButton(
                label: 'Check in now',
                icon: Icons.qr_code_scanner_rounded,
                color: AppColors.lime,
                foreground: AppColors.ink,
                onPressed: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  nav.push(MaterialPageRoute(builder: (_) => const CheckinScreen()));
                },
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.pop(context),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('Done'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Venues covered by a plan
// ---------------------------------------------------------------------------

class PlanVenuesScreen extends StatefulWidget {
  const PlanVenuesScreen({super.key, required this.plan});

  final Plan plan;

  @override
  State<PlanVenuesScreen> createState() => _PlanVenuesScreenState();
}

class _PlanVenuesScreenState extends State<PlanVenuesScreen> {
  late Future<List<VenueSummary>> _future = _load();

  Future<List<VenueSummary>> _load() => context.read<Session>().api.planVenues(widget.plan.id);

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    return Scaffold(
      appBar: AppBar(title: Text(plan.name)),
      body: AsyncBody<List<VenueSummary>>(
        future: _future,
        onRetry: _refresh,
        loading: const SkeletonList(count: 4, itemHeight: 110),
        builder: (context, venues) => RefreshIndicator(
          color: AppColors.primary,
          onRefresh: _refresh,
          child: venues.isEmpty
              ? ListView(children: const [
                  EmptyView(
                    icon: Icons.storefront_rounded,
                    title: 'No venues yet',
                    message: 'Partner venues for this plan are being onboarded. Check back soon.',
                  ),
                ])
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  itemCount: venues.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 16),
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${venues.length} ${venues.length == 1 ? 'venue' : 'venues'} on this pass',
                            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                        const SizedBox(height: 8),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final c in plan.categories)
                            Tag(venueVisual(c).label, icon: venueVisual(c).icon, color: venueVisual(c).color),
                        ]),
                      ]);
                    }
                    final v = venues[i - 1];
                    return VenueCard(venue: v, onTap: () => push(context, VenueDetailScreen(venueId: v.id)));
                  },
                ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Purchase history
// ---------------------------------------------------------------------------

class MySubscriptionsScreen extends StatefulWidget {
  const MySubscriptionsScreen({super.key});

  @override
  State<MySubscriptionsScreen> createState() => _MySubscriptionsScreenState();
}

class _MySubscriptionsScreenState extends State<MySubscriptionsScreen> {
  late Future<List<Subscription>> _future = _load();

  Future<List<Subscription>> _load() => context.read<Session>().api.mySubscriptions();

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My plans')),
      body: AsyncBody<List<Subscription>>(
        future: _future,
        onRetry: _refresh,
        loading: const SkeletonList(count: 4, itemHeight: 72),
        builder: (context, subs) => RefreshIndicator(
          color: AppColors.primary,
          onRefresh: _refresh,
          child: subs.isEmpty
              ? ListView(children: [
                  EmptyView(
                    icon: Icons.card_membership_rounded,
                    title: 'No plans yet',
                    message: 'Get a FITKEY Pass to unlock gyms, pools and studios near you.',
                    action: SizedBox(
                      width: 200,
                      child: AppButton(
                        label: 'See plans',
                        icon: Icons.key_rounded,
                        height: 48,
                        onPressed: () => Navigator.pushReplacement(
                            context, MaterialPageRoute(builder: (_) => const PlansScreen())),
                      ),
                    ),
                  ),
                ])
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  itemCount: subs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => _SubscriptionCard(sub: subs[i]),
                ),
        ),
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.sub});
  final Subscription sub;

  @override
  Widget build(BuildContext context) {
    final s = sub;
    final (label, color, icon) = switch (s.state) {
      'active' => ('ACTIVE', AppColors.green, Icons.check_circle_rounded),
      'upcoming' => ('UPCOMING', AppColors.blue, Icons.schedule_rounded),
      'cancelled' => ('CANCELLED', AppColors.red, Icons.cancel_rounded),
      _ => ('EXPIRED', AppColors.text3, Icons.history_rounded),
    };
    final isActive = s.state == 'active';
    final total = s.endsAt.difference(s.startsAt).inDays.clamp(1, 3650);
    final left = (s.endsAt.difference(DateTime.now()).inDays + 1).clamp(0, total);
    final cat = venueVisual(s.categories.isEmpty ? 'gym' : s.categories.first);

    return AppCard(
      padding: const EdgeInsets.all(14),
      gradient: isActive ? AppColors.passGradient : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColorFiltered(
              colorFilter: s.state == 'expired' || s.state == 'cancelled'
                  ? const ColorFilter.mode(Colors.grey, BlendMode.saturation)
                  : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
              child: Image.asset(cat.image, width: 52, height: 52, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.planName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800, color: isActive ? Colors.white : AppColors.text)),
              const SizedBox(height: 3),
              Text('${formatDate(s.startsAt)} → ${formatDate(s.endsAt)}',
                  style: TextStyle(
                      color: isActive ? Colors.white.withValues(alpha: 0.65) : AppColors.text2,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500)),
            ]),
          ),
          Tag(label, icon: icon, color: isActive ? AppColors.lime : color,
              bg: isActive ? AppColors.lime.withValues(alpha: 0.15) : null, dense: true),
        ]),
        if (isActive) ...[
          const SizedBox(height: 14),
          Row(children: [
            Text('$left days left',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
            const Spacer(),
            Text('Paid ${formatPaise(s.amountPaise)}',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 12.5, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: left / total,
              minHeight: 5,
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              valueColor: const AlwaysStoppedAnimation(AppColors.lime),
            ),
          ),
        ] else ...[
          const SizedBox(height: 10),
          const Divider(),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text(s.categories.map((c) => venueVisual(c).label).join(' • '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            Text('Paid ${formatPaise(s.amountPaise)}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
          ]),
        ],
      ]),
    );
  }
}
