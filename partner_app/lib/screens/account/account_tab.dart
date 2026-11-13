import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/brd_api.dart';
import '../../state/partner_session.dart';
import '../permissions/permissions_screen.dart';
import '../../ui/ui.dart';
import '../../widgets/brand.dart';
import '../../widgets/commission_plan_card.dart';
import '../../widgets/listing/documents_bank_step.dart' show BankAccountCard, OwnerKycCard;
import '../auth/profile_screen.dart';
import '../home/shell.dart';
import '../home/venue_tab_body.dart' show TabSection;
import '../notifications/notifications_screen.dart';

/// Account (BRD §9): profile, commission plan, bank & KYC, notifications, help, logout.
/// Bank & KYC are hidden while a FitKey employee is listing on behalf of the partner.
class AccountTab extends StatelessWidget {
  const AccountTab({super.key});

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You\'ll need your phone number and an OTP to log back in.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) await context.read<PartnerSession>().signOut();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PartnerSession>();
    final user = session.user;
    final shell = PartnerShell.of(context);
    final type = PartnerType.parse(user?.partnerType);
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          AppCard(
            onTap: () => push(context, const ProfileScreen(editing: true)),
            child: Row(
              children: [
                PersonAvatar(name: user?.name, size: 58),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user?.name ?? 'Partner',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        user?.phone ?? '',
                        style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600),
                      ),
                      if (user?.email != null)
                        Text(
                          user!.email!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.text3, fontSize: 12.5),
                        ),
                      if (type != null) ...[
                        const SizedBox(height: 6),
                        Tag(type.label, icon: Icons.badge_rounded, color: AppColors.purple, dense: true),
                      ],
                    ],
                  ),
                ),
                const Tag('EDIT', icon: Icons.edit_rounded, dense: true),
              ],
            ),
          ),
          const TabSection('Commission plan'),
          const CommissionPlanCard(showPayoutRule: true),
          if (!shell.acting) ...[
            const TabSection('Bank & KYC', subtitle: 'Payouts go to your verified bank account'),
            const OwnerKycCard(),
            const SizedBox(height: 12),
            const BankAccountCard(),
          ],
          const TabSection('More'),
          ToolRow(
            icon: Icons.notifications_rounded,
            color: AppColors.primary,
            title: 'Notifications',
            subtitle: 'Listing updates, bookings, renewals and payouts',
            onTap: () => push(context, const PartnerNotificationsScreen()),
          ),
          ToolRow(
            icon: Icons.verified_user_rounded,
            color: AppColors.teal,
            title: 'Permissions',
            subtitle: 'Location, camera and notifications',
            onTap: () => push(context, const PartnerPermissionsScreen()),
          ),
          ToolRow(
            icon: Icons.help_outline_rounded,
            color: AppColors.blue,
            title: 'Help & support',
            subtitle: 'E-mail the FITKEY partner team',
            onTap: () => showAppSheet<void>(context, builder: (_) => const _HelpSheet()),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            icon: const Icon(Icons.logout_rounded, color: AppColors.red),
            label: const Text('Log out', style: TextStyle(color: AppColors.red)),
            onPressed: () => _logout(context),
          ),
          const SizedBox(height: 28),
          const Center(child: Opacity(opacity: 0.55, child: PartnerLockup(size: 22))),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Grow your fitness business with FITKEY',
              style: TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _HelpSheet extends StatelessWidget {
  const _HelpSheet();

  static const _email = 'support@fitkey.in';

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData i, String t, String s, Uri uri) => ListTile(
      leading: IconBubble(i, color: AppColors.primary, size: 40),
      title: Text(t, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(s),
      onTap: () => launchUrl(uri, mode: LaunchMode.externalApplication),
    );
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('Help & support', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Mon–Sat, 9 AM – 7 PM', style: TextStyle(color: AppColors.text2)),
          ),
          tile(Icons.mail_rounded, 'E-mail', _email, Uri(scheme: 'mailto', path: _email)),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
