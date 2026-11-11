import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/step_counter.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';

/// One-time "make FITKEY work for you" screen: explains and asks for location, physical activity (steps),
/// contacts and notifications. Each is optional; the member can change them later from Profile → Permissions.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key, this.onboarding = false});

  /// Shown after sign-in (has a "Continue" button) vs opened from Profile.
  final bool onboarding;

  static const _kSeen = 'permissions.onboarding.v1';

  /// Opens the screen once per install, after the member signs in (mobile only).
  static Future<void> showOnce(BuildContext context) async {
    if (kIsWeb) return;
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(_kSeen) == true) return;
      await p.setBool(_kSeen, true);
    } catch (_) {
      return;
    }
    if (context.mounted) await push(context, const PermissionsScreen(onboarding: true));
  }

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _Item {
  const _Item(this.permission, this.icon, this.color, this.title, this.why);
  final Permission permission;
  final IconData icon;
  final Color color;
  final String title;
  final String why;
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver {
  final _status = <Permission, PermissionStatus>{};
  Permission? _busy;

  List<_Item> get _items => [
        const _Item(
          Permission.locationWhenInUse,
          Icons.location_on_rounded,
          AppColors.blue,
          'Location',
          'Record the route of your walks, runs, rides and trips, measure the distance and the area you cover, '
              'and show gyms near you.',
        ),
        _Item(
          defaultTargetPlatform == TargetPlatform.iOS ? Permission.sensors : Permission.activityRecognition,
          Icons.directions_walk_rounded,
          AppColors.green,
          'Physical activity (steps)',
          'Count your steps all day with your phone\'s motion sensor, even when FITKEY is closed.',
        ),
        const _Item(
          Permission.contacts,
          Icons.contacts_rounded,
          AppColors.purple,
          'Contacts',
          'See which friends are already on FITKEY so you can work out together. Numbers are scrambled (hashed) on '
              'your phone before matching — we never store your contact list.',
        ),
        const _Item(
          Permission.notification,
          Icons.notifications_active_rounded,
          AppColors.primary,
          'Notifications',
          'Booking reminders, coin rewards, friend requests and the live notification while a trip is recording.',
        ),
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    for (final i in _items) {
      try {
        _status[i.permission] = await i.permission.status;
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _ask(_Item i) async {
    final current = _status[i.permission];
    if (current != null && current.isPermanentlyDenied) {
      await openAppSettings();
      return;
    }
    setState(() => _busy = i.permission);
    try {
      if (i.permission == Permission.locationWhenInUse) {
        if (!await Geolocator.isLocationServiceEnabled()) await Geolocator.openLocationSettings();
        await Geolocator.requestPermission();
      } else if (i.icon == Icons.directions_walk_rounded) {
        await StepCounter.instance.requestAndStart(context.read<Session>().api);
      } else {
        await i.permission.request();
      }
    } catch (_) {}
    if (mounted) setState(() => _busy = null);
    await _refresh();
  }

  Future<void> _allowAll() async {
    for (final i in _items) {
      final s = _status[i.permission];
      if (s == null || !(s.isGranted || s.isLimited)) await _ask(i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allGranted = _items.every((i) => _status[i.permission]?.isGranted == true);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.onboarding ? 'Set up FITKEY' : 'Permissions'),
        automaticallyImplyLeading: !widget.onboarding,
        actions: [
          if (widget.onboarding)
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Skip')),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        if (widget.onboarding) ...[
          const Text('Make FITKEY work for you',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
          const SizedBox(height: 6),
          const Text(
            'Allow these so we can count your steps, track how far you travel and show it on your map. '
            'Everything is optional — you can change it any time in Profile → Permissions.',
            style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w500, height: 1.4),
          ),
          const SizedBox(height: 18),
        ],
        for (final i in _items) ...[
          _row(i),
          const SizedBox(height: 10),
        ],
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: widget.onboarding
              ? AppButton(
                  label: allGranted ? 'Continue' : 'Allow all',
                  icon: allGranted ? Icons.arrow_forward_rounded : Icons.check_rounded,
                  onPressed: allGranted ? () => Navigator.pop(context) : _allowAll,
                )
              : AppButton(
                  label: 'Open phone settings',
                  icon: Icons.settings_rounded,
                  color: AppColors.surfaceAlt,
                  foreground: AppColors.text,
                  onPressed: openAppSettings,
                ),
        ),
      ),
    );
  }

  Widget _row(_Item i) {
    final s = _status[i.permission];
    final granted = s != null && (s.isGranted || s.isLimited);
    final blocked = s != null && s.isPermanentlyDenied;
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconBubble(i.icon, color: i.color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(i.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 3),
            Text(i.why, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
          ]),
        ),
        const SizedBox(width: 10),
        granted
            ? const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Icon(Icons.check_circle_rounded, color: AppColors.green),
              )
            : SizedBox(
                height: 34,
                child: FilledButton(
                  onPressed: _busy == null ? () => _ask(i) : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: i.color,
                    // The app theme makes buttons full-width; beside text in a Row that crushes the text.
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  child: Text(_busy == i.permission ? '…' : (blocked ? 'Settings' : 'Allow')),
                ),
              ),
      ]),
    );
  }
}
