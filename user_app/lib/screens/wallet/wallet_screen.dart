import 'package:fitkey_core/fitkey_core.dart' show formatDate, formatPaise, formatShortDate;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/wallet_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../plans/plans_screen.dart';
import '../store/store_screen.dart';
import 'coins.dart';
import 'low_balance_banner.dart';
import 'refer_earn_screen.dart';

typedef _Data = ({CoinWallet wallet, List<CoinEntry> ledger, List<PassPurchase> purchases});

/// BRD §3/§4 — Wallet: FitKey coins or sessions left (with validity), referral coins (active / locked), ProveIt
/// coins, the rules for each, purchase history and coin activity.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  late Future<_Data> _future = _load();
  int _bannerKey = 0;

  Future<_Data> _load() async {
    final api = context.read<Session>().api;
    final w = await api.wallet();
    final purchases = await api.passPurchases();
    return (wallet: w.wallet, ledger: w.ledger, purchases: purchases);
  }

  Future<void> _refresh() async {
    final f = _load();
    setState(() {
      _future = f;
      _bannerKey++;
    });
    await f;
  }

  Future<void> _open(Widget screen) async {
    await push(context, screen);
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet')),
      body: FutureBuilder<_Data>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 5, itemHeight: 120);
          if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _refresh);
          final d = snap.data!;
          final w = d.wallet;
          return RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                LowBalanceBanner(key: ValueKey('low-$_bannerKey')),
                if (w.legacyPassName != null) ...[
                  _LegacyPass(name: w.legacyPassName!, endsAt: w.legacyPassEndsAt),
                  const SizedBox(height: 12),
                ],
                _FitKeyCoinsCard(wallet: w, onTopUp: () => _open(const PlansScreen(initialModel: 'coins'))),
                const SizedBox(height: 12),
                _SessionsCard(wallet: w, onRenew: () => _open(const PlansScreen(initialModel: 'sessions'))),
                const SizedBox(height: 12),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: _SmallBalance(
                      title: 'Referral coins',
                      value: w.referralCoins,
                      locked: w.referralLocked,
                      icon: Icons.group_rounded,
                      color: AppColors.green,
                      rule: 'Store & FitKey pass checkout · up to ${w.rules.passMaxCoinPct}%',
                      onTap: () => _open(const ReferEarnScreen()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SmallBalance(
                      title: 'ProveIt coins',
                      value: w.proveitCoins,
                      locked: 0,
                      icon: Icons.emoji_events_rounded,
                      color: AppColors.blue,
                      rule: 'Store only · usable instantly',
                      onTap: () => _open(const StoreScreen()),
                    ),
                  ),
                ]),
                const SectionTitle('How your coins work'),
                _Rules(rules: w.rules),
                SectionTitle('Purchase history', subtitle: d.purchases.isEmpty ? null : '${d.purchases.length} FitKey passes'),
                _Purchases(purchases: d.purchases, onBuy: () => _open(const PlansScreen())),
                const SectionTitle('Coin activity'),
                CoinLedger(
                  entries: d.ledger,
                  emptyMessage: 'Buy a coin pack, invite a friend or complete a ProveIt challenge to get coins.',
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LegacyPass extends StatelessWidget {
  const _LegacyPass({required this.name, required this.endsAt});
  final String name;
  final DateTime? endsAt;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      gradient: AppColors.passGradient,
      child: Row(children: [
        const Icon(Icons.key_rounded, color: AppColors.lime, size: 26),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15.5)),
            Text(
              'Unlimited visits in your plan\'s categories${endsAt == null ? '' : ' till ${formatDate(endsAt!)}'} — no coins needed',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12.5, height: 1.35),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _FitKeyCoinsCard extends StatelessWidget {
  const _FitKeyCoinsCard({required this.wallet, required this.onTopUp});
  final CoinWallet wallet;
  final VoidCallback onTopUp;

  @override
  Widget build(BuildContext context) {
    final w = wallet;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const CoinIcon(size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('FitKey coins', style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700, fontSize: 12.5)),
              Text.rich(TextSpan(children: [
                TextSpan(
                    text: formatCoins(w.fitkeyCoins),
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                const TextSpan(text: '  coins', style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600)),
              ])),
            ]),
          ),
          SizedBox(
            width: 104,
            child: AppButton(label: 'Top up', icon: Icons.add_rounded, height: 42, onPressed: onTopUp),
          ),
        ]),
        const SizedBox(height: 10),
        Text(
          w.fitkeyCoins > 0 && w.fitkeyExpiresAt != null
              ? 'Next coins expire ${formatDate(w.fitkeyExpiresAt!)} · each visit deducts the centre\'s coin cost'
              : 'Buy a coin pack to pay per visit — each visit deducts the centre\'s coin cost',
          style: const TextStyle(color: AppColors.text3, fontSize: 12, height: 1.35),
        ),
      ]),
    );
  }
}

class _SessionsCard extends StatelessWidget {
  const _SessionsCard({required this.wallet, required this.onRenew});
  final CoinWallet wallet;
  final VoidCallback onRenew;

  @override
  Widget build(BuildContext context) {
    final w = wallet;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconBubble(Icons.event_available_rounded, color: AppColors.purple, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Sessions left', style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700, fontSize: 12.5)),
              Text.rich(TextSpan(children: [
                TextSpan(
                    text: '${w.sessionsLeft}',
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                TextSpan(
                    text: w.sessionsLeft == 1 ? '  session' : '  sessions',
                    style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600)),
              ])),
            ]),
          ),
          SizedBox(
            width: 104,
            child: AppButton(
              label: w.sessionsLeft > 0 ? 'Renew' : 'Get plan',
              icon: Icons.autorenew_rounded,
              height: 42,
              color: AppColors.ink,
              onPressed: onRenew,
            ),
          ),
        ]),
        const SizedBox(height: 10),
        if (w.sessionPlans.isEmpty)
          const Text('Session plans give a fixed number of visits — 1 session per visit at any centre.',
              style: TextStyle(color: AppColors.text3, fontSize: 12, height: 1.35))
        else
          for (final p in w.sessionPlans)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Expanded(
                  child: Text('${p.name} · ${p.sessionsLeft} of ${p.sessionsTotal} left',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                ),
                Text('Valid till ${formatDate(p.expiresAt)}',
                    style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ),
      ]),
    );
  }
}

class _SmallBalance extends StatelessWidget {
  const _SmallBalance({
    required this.title,
    required this.value,
    required this.locked,
    required this.icon,
    required this.color,
    required this.rule,
    required this.onTap,
  });
  final String title;
  final int value;
  final int locked;
  final IconData icon;
  final Color color;
  final String rule;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconBubble(icon, color: color, size: 34, iconSize: 18),
        const SizedBox(height: 10),
        Text(title, style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700, fontSize: 12.5)),
        Text(formatCoins(value), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        if (locked > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              const Icon(Icons.lock_rounded, size: 12, color: AppColors.amber),
              const SizedBox(width: 3),
              Flexible(
                child: Text('${formatCoins(locked)} locked',
                    style: const TextStyle(color: Color(0xFFB86E00), fontWeight: FontWeight.w800, fontSize: 11.5)),
              ),
            ]),
          ),
        const SizedBox(height: 6),
        Text(rule, style: const TextStyle(color: AppColors.text3, fontSize: 11.5, height: 1.3)),
      ]),
    );
  }
}

class _Rules extends StatelessWidget {
  const _Rules({required this.rules});
  final WalletRules rules;

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.toll_rounded, AppColors.amber, 'FitKey coins',
          'Bought in coin packs (1 coin = ₹1). Pay for visits — each centre has its own coin cost. Expire with the pack.'),
      (Icons.event_available_rounded, AppColors.purple, 'Sessions',
          '1 session per visit at any centre. Unused sessions end with the plan. With both, a visit uses a session first.'),
      (Icons.group_rounded, AppColors.green, 'Referral coins',
          'Welcome bonus and referral rewards. Locked until you buy your first FitKey pass. Use on Store orders (up to '
              '${rules.storeMaxCoinPct}%) and FitKey pass checkout (up to ${rules.passMaxCoinPct}%) — not on visits.'),
      (Icons.emoji_events_rounded, AppColors.blue, 'ProveIt coins',
          'Earned in ProveIt challenges. Usable instantly, in the Store only — used before referral coins.'),
      (Icons.undo_rounded, AppColors.teal, 'Cancellations',
          'Cancel a booking within the free window and the coins or session come straight back.'),
    ];
    return AppCard(
      child: Column(children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i < items.length - 1 ? 14 : 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              IconBubble(items[i].$1, color: items[i].$2, size: 34, iconSize: 17),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(items[i].$3, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(items[i].$4, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.4)),
                ]),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _Purchases extends StatelessWidget {
  const _Purchases({required this.purchases, required this.onBuy});
  final List<PassPurchase> purchases;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    if (purchases.isEmpty) {
      return AppCard(
        child: EmptyView(
          icon: Icons.receipt_long_rounded,
          title: 'No FitKey pass yet',
          message: 'Choose coins (pay per visit) or a session plan (fixed visits).',
          action: SizedBox(
            width: 200,
            child: AppButton(label: 'See passes', icon: Icons.key_rounded, height: 46, onPressed: onBuy),
          ),
        ),
      );
    }
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        for (var i = 0; i < purchases.length; i++) ...[
          _row(purchases[i]),
          if (i < purchases.length - 1) const Divider(indent: 64, height: 1),
        ],
      ]),
    );
  }

  Widget _row(PassPurchase p) {
    final (label, color) = switch (p.state) {
      'active' => ('Active', AppColors.green),
      'used' => ('Used up', AppColors.text3),
      _ => ('Expired', AppColors.text3),
    };
    final balance = p.isCoinPack
        ? '${formatCoins(p.coinsRemaining)} of ${formatCoins(p.coins)} coins left'
        : '${p.sessionsLeft} of ${p.sessionsTotal} sessions left';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        p.isCoinPack
            ? const CoinIcon(size: 38)
            : const IconBubble(Icons.event_available_rounded, color: AppColors.purple, size: 38, iconSize: 19),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            Text('${formatShortDate(p.createdAt)} · $balance',
                style: const TextStyle(fontSize: 12, color: AppColors.text3)),
            Text(
              p.state == 'expired' ? 'Expired ${formatDate(p.expiresAt)}' : 'Valid till ${formatDate(p.expiresAt)}',
              style: const TextStyle(fontSize: 12, color: AppColors.text3),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(formatPaise(p.paidPaise), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
          if (p.coinsRedeemed > 0)
            Text('+ ${formatCoins(p.coinsRedeemed)} coins',
                style: const TextStyle(fontSize: 11.5, color: AppColors.green, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Tag(label, color: color, dense: true),
        ]),
      ]),
    );
  }
}
