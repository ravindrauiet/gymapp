import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../state/session.dart';
import '../auth/profile_setup_screen.dart';
import '../goals/goal_selection_screen.dart';
import '../nutrition/fuel_log_screen.dart';
import '../nutrition/ai_food_scanner.dart';
import '../ai/ai_coach_screen.dart';
import '../store/store_screen.dart';
import '../trainers/trainers_screen.dart';
import '../health/attendance_screen.dart';
import '../health/health_report_screen.dart';
import '../plans/plans_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final user = session.user;
    final sub = session.subscription;

    void open(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

    return Scaffold(
      appBar: AppBar(title: const Text('Me')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Row(children: [
            Avatar(name: user?.name, radius: 34),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(user?.name ?? '', style: Theme.of(context).textTheme.titleLarge),
                Text(user?.phone ?? '', style: const TextStyle(color: FkColors.textSecondary)),
                if (user?.city != null) Text(user!.city!, style: const TextStyle(color: FkColors.textSecondary)),
              ]),
            ),
            IconButton(
              tooltip: 'Edit profile',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => open(const ProfileSetupScreen(editing: true)),
            ),
          ]),
          const SizedBox(height: 20),
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: const Icon(Icons.key, color: FkColors.lime),
              title: Text(sub?.planName ?? 'No active plan', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(sub == null ? 'Get a plan to start checking in' : 'Valid till ${formatDate(sub.endsAt)}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => open(const PlansScreen()),
            ),
          ),
          const SizedBox(height: 16),
          _tile(Icons.smart_toy, 'FitKey AI Coach (ChatGPT)', () => open(const AiCoachScreen()), color: FkColors.sky),
          _tile(Icons.camera_alt, 'AI Food & Label Scanner', () => open(const AiFoodScannerScreen()), color: FkColors.lime),
          _tile(Icons.track_changes, 'Fitness Goal & Calorie Baselines', () => open(const GoalSelectionScreen(isEditing: true)), color: FkColors.lime),
          _tile(Icons.restaurant, 'Fuel Log (Nutrition Diary)', () => open(const FuelLogScreen()), color: FkColors.orange),
          _tile(Icons.shopping_bag, 'Marketplace Orders', () => open(const StoreScreen()), color: FkColors.violet),
          _tile(Icons.sports, 'FitPro Trainer Bookings', () => open(const TrainersScreen()), color: FkColors.sky),
          _tile(Icons.card_membership, 'My plans & payments', () => open(const MySubscriptionsScreen())),
          _tile(Icons.insights, 'Progress report', () => open(const HealthReportScreen())),
          _tile(Icons.history, 'Attendance history', () => open(const AttendanceScreen())),
          _tile(Icons.list_alt, 'Activity log', () => open(const ActivityLogScreen())),
          const Divider(height: 32),
          _tile(Icons.help_outline, 'Help & support', () => showSnack(context, 'Write to support@fitkey.in')),
          _tile(Icons.logout, 'Log out', () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Log out?'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                  TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Log out')),
                ],
              ),
            );
            if (ok == true && context.mounted) await context.read<Session>().signOut();
          }, color: FkColors.danger),
          const SizedBox(height: 24),
          const Center(child: FitKeyLogo(size: 24)),
          const SizedBox(height: 6),
          const Center(
            child: Text('Your Key to Fitness Everywhere.', style: TextStyle(color: FkColors.textSecondary, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _tile(IconData icon, String title, VoidCallback onTap, {Color? color}) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: color ?? FkColors.textSecondary),
        title: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w500)),
        trailing: const Icon(Icons.chevron_right, color: FkColors.textSecondary),
        onTap: onTap,
      );
}
