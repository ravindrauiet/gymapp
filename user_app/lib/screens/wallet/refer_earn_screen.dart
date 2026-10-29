import 'package:fitkey_core/fitkey_core.dart' show formatShortDate;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/wallet_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../plans/plans_screen.dart';
import 'coins.dart';

typedef _WalletData = ({CoinWallet wallet, List<CoinEntry> ledger, ReferralInfo referrals});

/// BRD §9 — Refer & Earn: share your code, track invited friends, and see your FitKey Coins.
class ReferEarnScreen extends StatefulWidget {
  const ReferEarnScreen({super.key});

  @override
  State<ReferEarnScreen> createState() => _ReferEarnScreenState();
}

class _ReferEarnScreenState extends State<ReferEarnScreen> {
  late Future<_WalletData> _future = _load();

  Future<_WalletData> _load() async {
    final api = context.read<Session>().api;
    final results = await Future.wait([api.wallet(), api.referrals()]);
    final w = results[0] as ({CoinWallet wallet, List<CoinEntry> ledger});
    return (wallet: w.wallet, ledger: w.ledger, referrals: results[1] as ReferralInfo);
  }

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Refer & Earn')),
      body: FutureBuilder<_WalletData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const _Skeleton();
          if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _refresh);
          final d = snap.data!;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _Hero(wallet: d.wallet, reward: d.referrals.rewardPerReferral),
                const SizedBox(height: 14),
                _CodeCard(info: d.referrals),
                if (d.referrals.canApplyCode) ...[
                  const SizedBox(height: 14),
                  _HaveACode(onApplied: _refresh),
                ] else if (d.referrals.referredBy != null) ...[
                  const SizedBox(height: 12),
                  _InvitedBy(name: d.referrals.referredBy!),
                ],
                const SectionTitle('How it works'),
                _HowItWorks(reward: d.referrals.rewardPerReferral),
                SectionTitle('Your referrals',
                    subtitle: d.referrals.invited == 0
                        ? null
                        : '${d.referrals.invited} invited · ${d.referrals.passBought} bought a pass · '
                            '${formatCoins(d.referrals.coinsEarned)} coins earned'),
                _ReferralList(info: d.referrals),
                const SectionTitle('Coin history'),
                _Ledger(entries: d.ledger),
                const SizedBox(height: 18),
                const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: AppColors.text3),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Coins are saved safely in your FitKey wallet. You earn 1 coin for every ₹1 you pay for a pass, '
                      'plus a reward for every friend who buys their first pass. We\'ll notify you when coins can be redeemed.',
                      style: TextStyle(fontSize: 12, color: AppColors.text3, height: 1.45),
                    ),
                  ),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Hero extends StatelessWidget {
  const _Hero({required this.wallet, required this.reward});
  final CoinWallet wallet;
  final int reward;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(gradient: AppColors.passGradient, borderRadius: BorderRadius.circular(24), boxShadow: AppShadows.card),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        Positioned(
          right: -30,
          top: -30,
          child: Container(
            width: 150,
            height: 150,
            decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.amber.withValues(alpha: 0.10)),
          ),
        ),
        const Positioned(right: 22, top: 22, child: CoinIcon(size: 58)),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('FITKEY COINS',
                style: TextStyle(color: AppColors.lime, fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1.6)),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(formatCoins(wallet.available),
                  style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: -1.2, height: 1)),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('available', style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 14),
            if (wallet.locked > 0)
              Tap(
                onTap: () => push(context, const PlansScreen()),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.lock_rounded, size: 16, color: AppColors.amber),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${formatCoins(wallet.locked)} coins unlock with your first pass',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                    const Text('Get pass', style: TextStyle(color: AppColors.lime, fontWeight: FontWeight.w800, fontSize: 12.5)),
                    const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.lime),
                  ]),
                ),
              )
            else
              Text('${formatCoins(wallet.totalEarned)} coins earned so far',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 16),
            Container(height: 1, color: Colors.white.withValues(alpha: 0.1)),
            const SizedBox(height: 14),
            Text('Invite friends, earn $reward coins each',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
            const SizedBox(height: 4),
            Text('You get $reward coins when a friend you invite buys their first FitKey Pass.',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 12.5, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.info});
  final ReferralInfo info;

  Future<void> _copy(BuildContext context, String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();
    if (context.mounted) toast(context, '$what copied', icon: Icons.copy_rounded);
  }

  Future<void> _whatsApp(BuildContext context) async {
    final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(info.shareMessage)}');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!ok && context.mounted) await _more(context);
  }

  Future<void> _instagram(BuildContext context) async {
    // Instagram can't take pre-filled text, so copy the invite first and open the DM inbox.
    await Clipboard.setData(ClipboardData(text: info.shareMessage));
    if (context.mounted) toast(context, 'Invite copied — paste it in an Instagram chat', icon: Icons.copy_rounded);
    var ok = false;
    if (!kIsWeb) {
      ok = await launchUrl(Uri.parse('instagram://direct-inbox'), mode: LaunchMode.externalApplication).catchError((_) => false);
    }
    if (!ok) {
      await launchUrl(Uri.parse('https://www.instagram.com/direct/inbox/'), mode: LaunchMode.externalApplication)
          .catchError((_) => false);
    }
  }

  Future<void> _more(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(ShareParams(
        text: info.shareMessage,
        subject: 'Join me on FITKEY',
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } catch (_) {
      if (context.mounted) await _copy(context, info.shareMessage, 'Invite');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Your referral code',
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.text2, fontSize: 13)),
        const SizedBox(height: 10),
        Tap(
          onTap: () => _copy(context, info.code, 'Code'),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.35), width: 1.4),
            ),
            child: Row(children: [
              Expanded(
                child: Text(info.code,
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 3, color: AppColors.primaryDeep)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(10)),
                child: const Row(children: [
                  Icon(Icons.copy_rounded, size: 16, color: Colors.white),
                  SizedBox(width: 6),
                  Text('Copy', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
                ]),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: _ShareButton(
                label: 'WhatsApp', icon: Icons.chat_rounded, color: const Color(0xFF25D366), onTap: () => _whatsApp(context)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ShareButton(
                label: 'Instagram', icon: Icons.camera_alt_rounded, color: AppColors.pink, onTap: () => _instagram(context)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ShareButton(
                label: 'Copy link', icon: Icons.link_rounded, color: AppColors.blue,
                onTap: () => _copy(context, info.shareLink, 'Link')),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Builder(
              builder: (ctx) =>
                  _ShareButton(label: 'More', icon: Icons.ios_share_rounded, color: AppColors.ink, onTap: () => _more(ctx)),
            ),
          ),
        ]),
      ]),
    );
  }
}

class _ShareButton extends StatelessWidget {
  const _ShareButton({required this.label, required this.icon, required this.color, required this.onTap});
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: Column(children: [
        Container(
          height: 50,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
          child: Center(child: Icon(icon, color: color, size: 24)),
        ),
        const SizedBox(height: 6),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.text2)),
      ]),
    );
  }
}

class _HaveACode extends StatelessWidget {
  const _HaveACode({required this.onApplied});
  final Future<void> Function() onApplied;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () async {
        final applied = await showAppSheet<bool>(context, builder: (_) => const _ApplyCodeSheet());
        if (applied == true) await onApplied();
      },
      child: const Row(children: [
        IconBubble(Icons.card_giftcard_rounded, color: AppColors.purple, size: 40),
        SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Got a friend\'s code?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
            SizedBox(height: 2),
            Text('Add it before your first pass so your friend gets rewarded',
                style: TextStyle(fontSize: 12, color: AppColors.text2)),
          ]),
        ),
        Icon(Icons.chevron_right_rounded, color: AppColors.text3),
      ]),
    );
  }
}

class _ApplyCodeSheet extends StatefulWidget {
  const _ApplyCodeSheet();

  @override
  State<_ApplyCodeSheet> createState() => _ApplyCodeSheetState();
}

class _ApplyCodeSheetState extends State<_ApplyCodeSheet> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    installReferralCode().then((c) {
      if (c != null && mounted && _code.text.isEmpty) setState(() => _code.text = c);
    });
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final code = _code.text.trim();
    if (!RegExp(r'^[A-Za-z0-9]{4,12}$').hasMatch(code)) {
      setState(() => _error = 'Enter the code your friend shared, e.g. FK7QX2M9');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final msg = await context.read<Session>().api.applyReferralCode(code);
      if (!mounted) return;
      toast(context, msg);
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Enter referral code', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          const SizedBox(height: 6),
          const Text('Your friend earns coins when you buy your first FitKey Pass.',
              style: TextStyle(color: AppColors.text2, height: 1.4)),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            maxLength: 12,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]'))],
            onSubmitted: (_) => _apply(),
            decoration: InputDecoration(
              hintText: 'e.g. FK7QX2M9',
              counterText: '',
              prefixIcon: const Icon(Icons.card_giftcard_rounded),
              errorText: _error,
              errorMaxLines: 3,
            ),
          ),
          const SizedBox(height: 16),
          AppButton(label: 'Apply code', icon: Icons.check_rounded, busy: _busy, onPressed: _apply),
        ]),
      ),
    );
  }
}

class _InvitedBy extends StatelessWidget {
  const _InvitedBy({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        const Icon(Icons.favorite_rounded, color: AppColors.green, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text('You joined with $name\'s invite',
              style: const TextStyle(color: AppColors.green, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
      ]),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks({required this.reward});
  final int reward;

  @override
  Widget build(BuildContext context) {
    final steps = [
      (Icons.send_rounded, AppColors.blue, 'Share your code', 'Send your link on WhatsApp, Instagram or anywhere.'),
      (Icons.person_add_alt_1_rounded, AppColors.purple, 'Friend joins FITKEY', 'They install the app and sign up with your code.'),
      (Icons.key_rounded, AppColors.green, 'They buy a pass, you earn', 'You get $reward coins in your wallet, instantly.'),
    ];
    return AppCard(
      child: Column(children: [
        for (var i = 0; i < steps.length; i++)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Column(children: [
                IconBubble(steps[i].$1, color: steps[i].$2, size: 40, iconSize: 20),
                if (i < steps.length - 1)
                  Expanded(child: Container(width: 2, margin: const EdgeInsets.symmetric(vertical: 4), color: AppColors.line)),
              ]),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: 2, bottom: i < steps.length - 1 ? 18 : 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${i + 1}. ${steps[i].$3}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                    const SizedBox(height: 2),
                    Text(steps[i].$4, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
                  ]),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _ReferralList extends StatelessWidget {
  const _ReferralList({required this.info});
  final ReferralInfo info;

  @override
  Widget build(BuildContext context) {
    if (info.referrals.isEmpty) {
      return const AppCard(
        child: EmptyView(
          icon: Icons.group_add_rounded,
          title: 'No referrals yet',
          message: 'Share your code above — friends who join with it show up here.',
        ),
      );
    }
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        for (var i = 0; i < info.referrals.length; i++) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              PersonAvatar(name: info.referrals[i].name, photoUrl: info.referrals[i].avatarUrl, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(info.referrals[i].name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                  Text('Joined ${formatShortDate(info.referrals[i].joinedAt)}',
                      style: const TextStyle(fontSize: 12, color: AppColors.text3)),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                info.referrals[i].passBought
                    ? const Tag('Pass bought', color: AppColors.green, icon: Icons.check_circle_rounded, dense: true)
                    : const Tag('Signed up', color: AppColors.amber, icon: Icons.hourglass_top_rounded, dense: true),
                if (info.referrals[i].coins > 0) ...[
                  const SizedBox(height: 4),
                  Text('+${formatCoins(info.referrals[i].coins)} coins',
                      style: const TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: 12)),
                ],
              ]),
            ]),
          ),
          if (i < info.referrals.length - 1) const Divider(indent: 66, height: 1),
        ],
      ]),
    );
  }
}

class _Ledger extends StatelessWidget {
  const _Ledger({required this.entries});
  final List<CoinEntry> entries;

  (IconData, Color) _visual(CoinEntry e) => switch (e.kind) {
        'welcome_bonus' => (Icons.card_giftcard_rounded, AppColors.purple),
        'plan_purchase' => (Icons.key_rounded, AppColors.primary),
        'referral_reward' => (Icons.group_rounded, AppColors.green),
        _ => (Icons.toll_rounded, AppColors.amber),
      };

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const AppCard(
        child: EmptyView(
          icon: Icons.toll_rounded,
          color: AppColors.amber,
          title: 'No coins yet',
          message: 'Buy a FitKey Pass or invite a friend to start earning.',
        ),
      );
    }
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        for (var i = 0; i < entries.length; i++) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              IconBubble(_visual(entries[i]).$1, color: _visual(entries[i]).$2, size: 38, iconSize: 19),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(entries[i].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  Text(
                    [formatShortDate(entries[i].createdAt), ?entries[i].subtitle].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.text3),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${entries[i].amount > 0 ? '+' : ''}${formatCoins(entries[i].amount)}',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: entries[i].locked ? AppColors.text3 : (entries[i].amount > 0 ? AppColors.green : AppColors.red))),
                if (entries[i].locked)
                  const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.lock_rounded, size: 11, color: AppColors.amber),
                    SizedBox(width: 3),
                    Text('Locked', style: TextStyle(fontSize: 11, color: AppColors.amber, fontWeight: FontWeight.w700)),
                  ]),
              ]),
            ]),
          ),
          if (i < entries.length - 1) const Divider(indent: 64, height: 1),
        ],
      ]),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SkeletonBox(height: 230, radius: 24),
          SizedBox(height: 14),
          SkeletonBox(height: 160, radius: 20),
          SizedBox(height: 28),
          SkeletonBox(height: 20, width: 140),
          SizedBox(height: 14),
          SkeletonBox(height: 180, radius: 20),
        ]),
      ),
    );
  }
}
