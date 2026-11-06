import 'package:fitkey_core/fitkey_core.dart' show formatDate, formatPaise;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/wallet_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../../widgets/venue_card.dart';
import '../checkin/checkin_screen.dart';
import '../explore/venue_detail_screen.dart';
import '../wallet/coins.dart';
import '../wallet/wallet_screen.dart';

String _validity(int days) => switch (days) {
      7 => '7 days',
      30 || 31 => '30 days',
      90 || 91 || 92 => '3 months',
      180 || 182 || 183 => '6 months',
      365 || 366 => '12 months',
      _ => '$days days',
    };

typedef _PlansData = ({PassCatalog catalog, CoinWallet wallet});

/// BRD §3 — FitKey pass in two models. Choose **Coins** (buy a coin pack; each visit deducts the centre's coin cost)
/// or **Sessions** (a fixed number of visits; 1 session per visit at any centre), then a pack / plan, then pay.
/// [initialModel] is 'coins' or 'sessions' (e.g. from the low-balance banner).
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key, this.initialModel});

  final String? initialModel;

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  late Future<_PlansData> _future = _load();
  late String _model = widget.initialModel == 'sessions' ? 'sessions' : 'coins';

  Future<_PlansData> _load() async {
    final api = context.read<Session>().api;
    final catalog = await api.passCatalog();
    final wallet = await api.wallet();
    return (catalog: catalog, wallet: wallet.wallet);
  }

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f;
  }

  Future<void> _buy(_Item item) async {
    final result = await showAppSheet<PassPurchaseResult>(context, builder: (_) => _CheckoutSheet(item: item));
    if (result == null || !mounted) return;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (ctx, _, _) => _PurchaseSuccess(result: result),
      transitionBuilder: (ctx, a, _, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)), child: child),
      ),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final legacy = context.watch<Session>().subscription;
    return Scaffold(
      appBar: AppBar(
        title: const Text('FITKEY Pass'),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await push(context, const WalletScreen());
              if (mounted) _refresh();
            },
            icon: const Icon(Icons.account_balance_wallet_rounded, size: 18),
            label: const Text('Wallet'),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _refresh,
        child: FutureBuilder<_PlansData>(
          future: _future,
          builder: (context, snap) {
            final loading = snap.connectionState != ConnectionState.done;
            final d = snap.data;
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
              children: [
                if (loading)
                  ..._skeleton()
                else if (snap.hasError)
                  ErrorView(error: snap.error!, onRetry: _refresh)
                else ...[
                  _PassHero(wallet: d!.wallet, legacy: legacy),
                  const SectionTitle('How do you want to work out?', subtitle: 'You can hold both — a visit uses a session first'),
                  Row(children: [
                    Expanded(
                      child: _ModelCard(
                        selected: _model == 'coins',
                        icon: Icons.toll_rounded,
                        color: AppColors.amber,
                        title: 'Coins',
                        subtitle: 'Pay per visit. Each centre has its own coin cost.',
                        onTap: () => setState(() => _model = 'coins'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ModelCard(
                        selected: _model == 'sessions',
                        icon: Icons.event_available_rounded,
                        color: AppColors.purple,
                        title: 'Sessions',
                        subtitle: 'Fixed visits. 1 session per visit, any centre.',
                        onTap: () => setState(() => _model = 'sessions'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  ...(_model == 'coins' ? _coinPacks(d.catalog) : _sessionPlans(d.catalog)),
                ],
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
        const Shimmer(child: SkeletonBox(height: 150, radius: 24)),
        const SizedBox(height: 24),
        const Shimmer(child: SkeletonBox(height: 110, radius: 20)),
        const SizedBox(height: 16),
        for (var i = 0; i < 3; i++) ...[
          const Shimmer(child: SkeletonBox(height: 120, radius: 20)),
          const SizedBox(height: 12),
        ],
      ];

  List<Widget> _coinPacks(PassCatalog c) {
    if (c.coinPacks.isEmpty) {
      return const [
        EmptyView(icon: Icons.toll_rounded, title: 'No coin packs right now', message: 'Pull down to refresh, or try a session plan.'),
      ];
    }
    final best = c.coinPacks.reduce((a, b) => a.coins / a.pricePaise >= b.coins / b.pricePaise ? a : b);
    return [
      SectionTitle('Coin packs', subtitle: '1 coin = ₹1 · valid ${_validity(c.coinPacks.first.validityDays)}'),
      for (final p in c.coinPacks) ...[
        _ItemCard(
          item: _Item.pack(p),
          highlight: p.bonusCoins > 0 && p.id == best.id,
          onBuy: () => _buy(_Item.pack(p)),
        ),
        const SizedBox(height: 12),
      ],
      if (c.categoryCosts.isNotEmpty) ...[
        const SectionTitle('What a visit costs', subtitle: 'Coins per visit by centre type (some centres differ)'),
        AppCard(
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final cc in c.categoryCosts)
              Tag('${venueVisual(cc.category).label} · ${formatCoins(cc.coins)}',
                  icon: venueVisual(cc.category).icon, color: venueVisual(cc.category).color),
          ]),
        ),
      ],
    ];
  }

  List<Widget> _sessionPlans(PassCatalog c) {
    if (c.sessionPlans.isEmpty) {
      return const [
        EmptyView(
            icon: Icons.event_available_rounded, title: 'No session plans right now', message: 'Pull down to refresh, or try coins.'),
      ];
    }
    final best = c.sessionPlans.reduce((a, b) => a.perSessionPaise <= b.perSessionPaise ? a : b);
    return [
      const SectionTitle('Session plans', subtitle: 'Unused sessions end with the plan'),
      for (final p in c.sessionPlans) ...[
        _ItemCard(item: _Item.plan(p), highlight: p.id == best.id, onBuy: () => _buy(_Item.plan(p))),
        const SizedBox(height: 12),
      ],
    ];
  }
}

/// A coin pack or a session plan, normalised for the cards and checkout.
class _Item {
  _Item.pack(CoinPack p)
      : kind = 'coin_pack',
        id = p.id,
        name = p.name,
        description = p.description,
        pricePaise = p.pricePaise,
        validityDays = p.validityDays,
        amount = p.coins,
        bonus = p.bonusCoins,
        perVisitPaise = null;

  _Item.plan(SessionPlan p)
      : kind = 'session_plan',
        id = p.id,
        name = p.name,
        description = p.description,
        pricePaise = p.pricePaise,
        validityDays = p.validityDays,
        amount = p.sessions,
        bonus = 0,
        perVisitPaise = p.perSessionPaise;

  final String kind;
  final String id;
  final String name;
  final String? description;
  final int pricePaise;
  final int validityDays;

  /// Coins (pack) or sessions (plan).
  final int amount;
  final int bonus;
  final int? perVisitPaise;

  bool get isPack => kind == 'coin_pack';
  String get amountLabel => isPack ? '${formatCoins(amount)} coins' : '$amount ${amount == 1 ? 'session' : 'sessions'}';
}

// ---------------------------------------------------------------------------

class _PassHero extends StatelessWidget {
  const _PassHero({required this.wallet, required this.legacy});
  final CoinWallet wallet;
  final ActiveSubscription? legacy;

  @override
  Widget build(BuildContext context) {
    final w = wallet;
    final hasAny = w.fitkeyCoins > 0 || w.sessionsLeft > 0 || legacy != null;
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
              if (hasAny)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: AppColors.green, borderRadius: BorderRadius.circular(20)),
                  child: const Text('ACTIVE', style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800)),
                ),
            ]),
            const SizedBox(height: 14),
            if (!hasAny) ...[
              const Text('One key.\nEvery workout.',
                  style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, height: 1.1, letterSpacing: -0.8)),
              const SizedBox(height: 8),
              Text('Gyms, pools, studios & courts near you — pay per visit with coins, or pick a set of sessions.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13.5, height: 1.4)),
            ] else ...[
              Row(children: [
                Expanded(child: _heroStat(formatCoins(w.fitkeyCoins), 'FitKey coins', w.fitkeyCoins > 0 ? w.fitkeyExpiresAt : null)),
                Container(width: 1, height: 44, color: Colors.white.withValues(alpha: 0.12)),
                const SizedBox(width: 16),
                Expanded(child: _heroStat('${w.sessionsLeft}', 'sessions left', w.sessionsLeft > 0 ? w.sessionsExpiresAt : null)),
              ]),
              if (legacy != null) ...[
                const SizedBox(height: 12),
                Text('${legacy!.planName} · unlimited visits till ${formatDate(legacy!.endsAt)}',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 12.5, fontWeight: FontWeight.w600)),
              ],
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

  Widget _heroStat(String value, String label, DateTime? expires) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: const TextStyle(color: AppColors.lime, fontSize: 30, fontWeight: FontWeight.w800, height: 1)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontWeight: FontWeight.w700, fontSize: 12.5)),
        if (expires != null)
          Text('till ${formatDate(expires)}', style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 11.5)),
      ]);
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.selected,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final bool selected;
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.10) : AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? color : AppColors.line, width: selected ? 1.8 : 1),
          boxShadow: selected ? null : AppShadows.soft,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            IconBubble(icon, color: color, size: 36, iconSize: 19),
            const Spacer(),
            Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                color: selected ? color : AppColors.text3, size: 20),
          ]),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(color: AppColors.text2, fontSize: 12, height: 1.35)),
        ]),
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item, required this.highlight, required this.onBuy});
  final _Item item;
  final bool highlight;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    final i = item;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppShadows.card,
        border: highlight ? Border.all(color: AppColors.primary, width: 1.6) : null,
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          i.isPack ? const CoinIcon(size: 40) : const IconBubble(Icons.event_available_rounded, color: AppColors.purple, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(i.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                ),
                if (highlight) ...[
                  const SizedBox(width: 6),
                  const Tag('BEST VALUE', color: AppColors.primary, solid: true, dense: true),
                ],
              ]),
              Text(
                '${i.amountLabel} · valid ${_validity(i.validityDays)}',
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ]),
          ),
          Text(formatPaise(i.pricePaise), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        ]),
        if (i.description != null && i.description!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(i.description!, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
        ],
        const SizedBox(height: 10),
        Row(children: [
          if (i.bonus > 0) Tag('+${formatCoins(i.bonus)} bonus coins', color: AppColors.green, icon: Icons.add_rounded, dense: true),
          if (i.perVisitPaise != null) Tag('${formatPaise(i.perVisitPaise!)} per visit', color: AppColors.green, dense: true),
          const Spacer(),
          SizedBox(
            width: 120,
            child: AppButton(
              label: 'Buy',
              icon: Icons.key_rounded,
              height: 42,
              color: highlight ? AppColors.primary : AppColors.ink,
              onPressed: onBuy,
            ),
          ),
        ]),
      ]),
    );
  }
}

class _Perks extends StatelessWidget {
  const _Perks();

  @override
  Widget build(BuildContext context) {
    const perks = [
      (Icons.qr_code_scanner_rounded, 'Scan & enter', 'Book a slot, then check in with a QR or desk code', AppColors.primary),
      (Icons.undo_rounded, 'Free cancellation', 'Cancel in time and your coins or session come back', AppColors.teal),
      (Icons.group_rounded, 'Use referral coins', 'Pay up to 50% of a pass with referral coins', AppColors.green),
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
  const _CheckoutSheet({required this.item});
  final _Item item;

  @override
  State<_CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends State<_CheckoutSheet> {
  Redeemable? _coins;
  bool _useCoins = false;
  bool _paying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    context.read<Session>().api.redeemable('pass', widget.item.pricePaise).then((r) {
      if (mounted) setState(() => _coins = r);
    }).catchError((_) {});
  }

  int get _coinsApplied => _useCoins ? (_coins?.coins ?? 0) : 0;
  int get _toPay => widget.item.pricePaise - _coinsApplied * 100;

  Future<void> _pay() async {
    final session = context.read<Session>();
    setState(() {
      _paying = true;
      _error = null;
    });
    try {
      final r = await session.api.buyPass(kind: widget.item.kind, id: widget.item.id, useCoins: _useCoins);
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      Navigator.pop(context, r);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _paying = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final c = _coins;
    final ends = DateTime.now().add(Duration(days: i.validityDays));
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Checkout', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(gradient: AppColors.passGradient, borderRadius: BorderRadius.circular(18)),
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              i.isPack ? const CoinIcon(size: 46) : const IconBubble(Icons.event_available_rounded, color: AppColors.lime, size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(i.isPack ? 'FITKEY COINS' : 'FITKEY SESSIONS',
                      style: const TextStyle(color: AppColors.lime, fontWeight: FontWeight.w800, fontSize: 10.5, letterSpacing: 1.6)),
                  const SizedBox(height: 2),
                  Text(i.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                  Text(i.amountLabel, style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12.5)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          _row(i.isPack ? 'Coins credited' : 'Visits included', i.amountLabel),
          _row('Valid till', formatDate(ends)),
          _row(i.isPack ? 'Used for' : 'Each visit', i.isPack ? 'Visits — centre\'s coin cost each' : '1 session, any centre'),
          const SizedBox(height: 6),
          if (c != null && c.coins > 0)
            Container(
              decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(14)),
              child: SwitchListTile.adaptive(
                value: _useCoins,
                onChanged: _paying ? null : (v) => setState(() => _useCoins = v),
                activeThumbColor: AppColors.green,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                title: Text('Use ${formatCoins(c.coins)} referral coins',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                subtitle: Text('Save ${formatPaise(c.coins * 100)} · up to ${c.maxPct}% of the price',
                    style: const TextStyle(fontSize: 12, color: AppColors.text2)),
              ),
            )
          else if (c != null && c.referralLocked > 0)
            _note(Icons.lock_rounded, AppColors.amber,
                'Your ${formatCoins(c.referralLocked)} locked referral coins activate with this purchase — use them on your next pass or in the Store.'),
          const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider()),
          if (_coinsApplied > 0) ...[
            _row('Price', formatPaise(i.pricePaise)),
            _row('Referral coins', '− ${formatPaise(_coinsApplied * 100)}'),
            const SizedBox(height: 4),
          ],
          Row(children: [
            const Text('To pay', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const Spacer(),
            Text(formatPaise(_toPay), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
          ]),
          const SizedBox(height: 12),
          _note(Icons.verified_user_rounded, AppColors.green,
              'Demo payments are enabled — your pass activates instantly and no card is charged.'),
          if (_error != null) ...[
            const SizedBox(height: 10),
            _note(Icons.error_outline_rounded, AppColors.red, _error!, bg: AppColors.redSoft),
          ],
          const SizedBox(height: 16),
          AppButton(label: 'Pay ${formatPaise(_toPay)}', icon: Icons.lock_rounded, busy: _paying, onPressed: _pay),
        ]),
      ),
    );
  }

  Widget _note(IconData icon, Color color, String text, {Color bg = AppColors.surfaceAlt}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12, color: bg == AppColors.redSoft ? AppColors.red : AppColors.text2, fontWeight: FontWeight.w600)),
          ),
        ]),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Text(label, style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w500)),
          const SizedBox(width: 12),
          Expanded(child: Text(value, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      );
}

class _PurchaseSuccess extends StatelessWidget {
  const _PurchaseSuccess({required this.result});
  final PassPurchaseResult result;

  @override
  Widget build(BuildContext context) {
    final p = result.purchase;
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
                  decoration: BoxDecoration(color: AppColors.lime, shape: BoxShape.circle, boxShadow: AppShadows.glow(AppColors.lime)),
                  child: Icon(p.isCoinPack ? Icons.toll_rounded : Icons.event_available_rounded, size: 46, color: AppColors.ink),
                ),
              ),
              const SizedBox(height: 22),
              const Text("You're in! 🎉",
                  style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
              const SizedBox(height: 8),
              Text(
                p.isCoinPack
                    ? '${formatCoins(p.coins)} FitKey coins added, valid till ${formatDate(p.expiresAt)}.\nBook a slot at any centre to use them.'
                    : '${p.name}: ${p.sessionsTotal} sessions, valid till ${formatDate(p.expiresAt)}.\n1 session per visit at any centre.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.75), height: 1.45),
              ),
              if (result.coinsActivated > 0 || result.coinsUsed > 0)
                Container(
                  margin: const EdgeInsets.only(top: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.amber.withValues(alpha: 0.4)),
                  ),
                  child: Row(children: [
                    const CoinIcon(size: 30),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        [
                          if (result.coinsActivated > 0) 'Your ${formatCoins(result.coinsActivated)} referral coins are now active',
                          if (result.coinsUsed > 0) '${formatCoins(result.coinsUsed)} referral coins applied',
                        ].join(' · '),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13.5),
                      ),
                    ),
                  ]),
                ),
              const SizedBox(height: 24),
              AppButton(
                label: 'Open wallet',
                icon: Icons.account_balance_wallet_rounded,
                color: AppColors.lime,
                foreground: AppColors.ink,
                onPressed: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  nav.push(MaterialPageRoute(builder: (_) => const WalletScreen()));
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
