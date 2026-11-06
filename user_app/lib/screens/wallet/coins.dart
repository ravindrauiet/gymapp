import 'package:fitkey_core/fitkey_core.dart' show formatShortDate;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/wallet_api.dart';
import '../../ui/ui.dart';

final _coinFormat = NumberFormat.decimalPattern('en_IN');

/// 1600 → "1,600"
String formatCoins(int n) => _coinFormat.format(n);

/// The FitKey Coin mark: a gold disc with a key.
class CoinIcon extends StatelessWidget {
  const CoinIcon({super.key, this.size = 22});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFFFFD45C), Color(0xFFFFA41B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0xFFFFE9A8), width: size * 0.06),
        boxShadow: [BoxShadow(color: AppColors.amber.withValues(alpha: 0.35), blurRadius: size * 0.3, offset: Offset(0, size * 0.08))],
      ),
      child: Icon(Icons.key_rounded, size: size * 0.58, color: const Color(0xFF8A5300)),
    );
  }
}

/// One coin-ledger list (newest first) shared by the Wallet and Refer & Earn screens.
class CoinLedger extends StatelessWidget {
  const CoinLedger({super.key, required this.entries, this.emptyTitle = 'No coin activity yet', this.emptyMessage});
  final List<CoinEntry> entries;
  final String emptyTitle;
  final String? emptyMessage;

  static (IconData, Color) visual(CoinEntry e) => switch (e.kind) {
        'welcome_bonus' => (Icons.card_giftcard_rounded, AppColors.purple),
        'plan_purchase' || 'pack_purchase' => (Icons.key_rounded, AppColors.primary),
        'referral_reward' || 'referral_signup' || 'referral_credit' => (Icons.group_rounded, AppColors.green),
        'proveit' => (Icons.emoji_events_rounded, AppColors.blue),
        'visit' => (Icons.fitness_center_rounded, AppColors.ink),
        'visit_refund' => (Icons.undo_rounded, AppColors.teal),
        'store_redemption' => (Icons.shopping_bag_rounded, AppColors.pink),
        'pass_redemption' => (Icons.confirmation_number_rounded, AppColors.primary),
        _ => (Icons.toll_rounded, AppColors.amber),
      };

  static String walletName(String wallet) => switch (wallet) {
        'fitkey' => 'FitKey coins',
        'proveit' => 'ProveIt coins',
        _ => 'Referral coins',
      };

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return AppCard(
        child: EmptyView(icon: Icons.toll_rounded, color: AppColors.amber, title: emptyTitle, message: emptyMessage),
      );
    }
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        for (var i = 0; i < entries.length; i++) ...[
          _row(entries[i]),
          if (i < entries.length - 1) const Divider(indent: 64, height: 1),
        ],
      ]),
    );
  }

  Widget _row(CoinEntry e) {
    final (icon, color) = visual(e);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        IconBubble(icon, color: color, size: 38, iconSize: 19),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            Text(
              [formatShortDate(e.createdAt), walletName(e.wallet), ?e.subtitle].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.text3),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${e.amount > 0 ? '+' : ''}${formatCoins(e.amount)}',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: e.locked ? AppColors.text3 : (e.amount > 0 ? AppColors.green : AppColors.red))),
          if (e.locked)
            const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_rounded, size: 11, color: AppColors.amber),
              SizedBox(width: 3),
              Text('Locked', style: TextStyle(fontSize: 11, color: AppColors.amber, fontWeight: FontWeight.w700)),
            ]),
        ]),
      ]),
    );
  }
}
