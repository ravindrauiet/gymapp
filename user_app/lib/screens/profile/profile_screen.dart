import 'package:fitkey_core/fitkey_core.dart' show formatDate;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/wallet_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../../widgets/brand.dart';
import '../ai/ai_coach_screen.dart';
import '../auth/profile_setup_screen.dart';
import '../goals/goal_selection_screen.dart';
import '../health/attendance_screen.dart';
import '../health/health_report_screen.dart';
import '../healthstop/healthstop_screen.dart';
import '../nutrition/ai_food_scanner.dart';
import '../nutrition/fuel_log_screen.dart';
import '../plans/plans_screen.dart';
import '../store/store_screen.dart';
import '../trainers/trainers_screen.dart';
import '../wallet/coins.dart';
import '../wallet/refer_earn_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out of FITKEY?'),
        content: const Text('You can log back in anytime with your mobile number.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      await context.read<Session>().signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final user = session.user;
    final sub = session.subscription;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        AppCard(
          onTap: () => push(context, const ProfileSetupScreen(editing: true)),
          child: Row(children: [
            PersonAvatar(name: user?.name, size: 64),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(user?.name ?? '', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                const SizedBox(height: 2),
                Text(user?.phone ?? '', style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600)),
                if (user?.city != null)
                  Text(user!.city!, style: const TextStyle(color: AppColors.text3, fontSize: 12.5)),
              ]),
            ),
            const Text('Edit', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800)),
            const Icon(Icons.chevron_right_rounded, color: AppColors.primary),
          ]),
        ),
        const SizedBox(height: 14),
        Tap(
          onTap: () => push(context, const PlansScreen()),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(gradient: AppColors.passGradient, borderRadius: BorderRadius.circular(20)),
            child: Row(children: [
              const Icon(Icons.key_rounded, color: AppColors.lime, size: 28),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(sub?.planName ?? 'No active FitKey Pass',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(sub == null ? 'Get a pass to start checking in' : 'Valid till ${formatDate(sub.endsAt)} · ${sub.daysLeft} days left',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 12.5)),
                ]),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(color: AppColors.lime, borderRadius: BorderRadius.circular(10)),
                child: Text(sub == null ? 'Get pass' : 'Manage',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: AppColors.ink)),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        // Re-created (and reloaded) whenever the active pass changes, so coins earned on purchase show up.
        _ReferEarnCard(key: ValueKey('coins-${sub?.planId}-${sub?.endsAt}')),
        _Group(title: 'AI & nutrition', items: [
          _Item(Icons.auto_awesome_rounded, 'Chat with Mansi', 'Your AI fitness & diet coach', AppColors.purple,
              () => push(context, const AiCoachScreen())),
          _Item(Icons.document_scanner_rounded, 'AI meal & label scanner', 'Snap food to log macros', AppColors.green,
              () => push(context, const AiFoodScannerScreen())),
          _Item(Icons.restaurant_rounded, 'Fuel Log', 'Your daily meal diary', AppColors.amber,
              () => push(context, const FuelLogScreen())),
          _Item(Icons.track_changes_rounded, 'Fitness goal & targets', 'Calories and macros', AppColors.primary,
              () => push(context, const GoalSelectionScreen(isEditing: true))),
        ]),
        _Group(title: 'Activity', items: [
          _Item(Icons.insights_rounded, 'Progress report', 'Streaks, workouts, weight', AppColors.blue,
              () => push(context, const HealthReportScreen())),
          _Item(Icons.history_rounded, 'Check-in history', 'Every venue you visited', AppColors.teal,
              () => push(context, const AttendanceScreen())),
          _Item(Icons.list_alt_rounded, 'Activity log', 'Runs, rides & workouts', AppColors.pink,
              () => push(context, const ActivityLogScreen())),
        ]),
        _Group(title: 'Bookings & orders', items: [
          _Item(Icons.receipt_long_rounded, 'Passes & payments', 'Your FitKey Pass history', AppColors.ink,
              () => push(context, const MySubscriptionsScreen())),
          _Item(Icons.sports_rounded, 'Trainer sessions', 'Find trainers & your bookings', AppColors.blue,
              () => push(context, const TrainersScreen())),
          _Item(Icons.shopping_bag_rounded, 'Store & orders', 'Shop and track orders', AppColors.pink,
              () => push(context, const StoreScreen())),
          _Item(Icons.local_hospital_rounded, 'HealthStop', 'Clinics & chemists near you', AppColors.red,
              () => push(context, const HealthStopScreen())),
        ]),
        _Group(title: 'Support', items: [
          _Item(Icons.support_agent_rounded, 'Help & support', 'support@fitkey.in', AppColors.text2, () async {
            final ok = await launchUrl(Uri.parse('mailto:support@fitkey.in?subject=FITKEY%20app%20help'))
                .catchError((_) => false);
            if (!ok && context.mounted) toast(context, 'Write to us at support@fitkey.in', icon: Icons.mail_rounded);
          }),
          _Item(Icons.logout_rounded, 'Log out', null, AppColors.red, () => _logout(context)),
        ]),
        const SizedBox(height: 28),
        const Center(child: BrandLockup(size: 26)),
        const SizedBox(height: 6),
        const Center(
          child: Text('Your key to fitness, everywhere', style: TextStyle(color: AppColors.text3, fontSize: 12)),
        ),
      ]),
    );
  }
}

/// BRD §9 — Refer & Earn entry with the member's coin balance (available / locked), right below the pass card.
class _ReferEarnCard extends StatefulWidget {
  const _ReferEarnCard({super.key});

  @override
  State<_ReferEarnCard> createState() => _ReferEarnCardState();
}

class _ReferEarnCardState extends State<_ReferEarnCard> {
  static bool _deviceRegistered = false;
  CoinWallet? _wallet;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    if (!_deviceRegistered) {
      _deviceRegistered = true;
      context.read<Session>().api.registerDevice().catchError((_) {});
    }
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    try {
      final r = await context.read<Session>().api.wallet();
      if (mounted) setState(() => _wallet = r.wallet);
    } catch (_) {
      // Shown as a retry row below; the Refer & Earn link still works.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open() async {
    await push(context, const ReferEarnScreen());
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final w = _wallet;
    return AppCard(
      onTap: _open,
      padding: EdgeInsets.zero,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
          child: Row(children: [
            const CoinIcon(size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('FitKey Coins',
                    style: TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                if (_loading && w == null)
                  const Shimmer(child: SkeletonBox(height: 22, width: 110))
                else if (w == null)
                  Tap(
                    onTap: _load,
                    child: const Row(children: [
                      Text("Couldn't load balance", style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.text2)),
                      SizedBox(width: 4),
                      Icon(Icons.refresh_rounded, size: 18, color: AppColors.primary),
                    ]),
                  )
                else
                  Text.rich(TextSpan(children: [
                    TextSpan(
                        text: formatCoins(w.available),
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                    const TextSpan(
                        text: '  available',
                        style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
                  ])),
              ]),
            ),
            if (w != null && w.locked > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(color: AppColors.amberSoft, borderRadius: BorderRadius.circular(10)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.lock_rounded, size: 13, color: AppColors.amber),
                  const SizedBox(width: 4),
                  Text('${formatCoins(w.locked)} locked',
                      style: const TextStyle(color: Color(0xFFB86E00), fontWeight: FontWeight.w800, fontSize: 12)),
                ]),
              ),
          ]),
        ),
        if (w != null && w.locked > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, size: 14, color: AppColors.text3),
              const SizedBox(width: 6),
              Expanded(
                child: Text('${formatCoins(w.locked)} coins unlock with your first pass',
                    style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
          decoration: const BoxDecoration(
            gradient: AppColors.primaryGradient,
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
          ),
          child: const Row(children: [
            Icon(Icons.card_giftcard_rounded, color: Colors.white, size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Refer & Earn', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                Text('Get 100 coins for every friend who buys a pass',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: Colors.white),
          ]),
        ),
      ]),
    );
  }
}

class _Item {
  const _Item(this.icon, this.title, this.subtitle, this.color, this.onTap);
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color color;
  final VoidCallback onTap;
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.items});
  final String title;
  final List<_Item> items;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 24, 0, 10),
        child: Text(title.toUpperCase(),
            style: const TextStyle(fontSize: 12, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: AppColors.text3)),
      ),
      AppCard(
        padding: EdgeInsets.zero,
        child: Column(children: [
          for (var i = 0; i < items.length; i++) ...[
            InkWell(
              onTap: items[i].onTap,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  IconBubble(items[i].icon, color: items[i].color, size: 38),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(items[i].title,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14.5,
                              color: items[i].color == AppColors.red ? AppColors.red : AppColors.text)),
                      if (items[i].subtitle != null)
                        Text(items[i].subtitle!, style: const TextStyle(fontSize: 12, color: AppColors.text3)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
                ]),
              ),
            ),
            if (i < items.length - 1) const Divider(indent: 64, height: 1),
          ],
        ]),
      ),
    ]);
  }
}
