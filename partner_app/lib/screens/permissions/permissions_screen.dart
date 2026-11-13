import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ui/ui.dart';

/// Partner app permissions, asked once after sign-in (and from Account → Permissions):
/// location (pin your venue / current location), camera (venue photos, scan members' QR), notifications
/// (bookings, check-ins, listing status, payouts). Each is optional.
class PartnerPermissionsScreen extends StatefulWidget {
  const PartnerPermissionsScreen({super.key, this.onboarding = false});

  final bool onboarding;

  static const _kSeen = 'partner.permissions.onboarding.v1';

  /// Opens the screen once per install, after sign-in (mobile only).
  static Future<void> showOnce(BuildContext context) async {
    if (kIsWeb) return;
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(_kSeen) == true) return;
      await p.setBool(_kSeen, true);
    } catch (_) {
      return;
    }
    if (context.mounted) await push(context, const PartnerPermissionsScreen(onboarding: true));
  }

  @override
  State<PartnerPermissionsScreen> createState() => _PartnerPermissionsScreenState();
}

class _Item {
  const _Item(this.permission, this.icon, this.color, this.title, this.why);
  final Permission permission;
  final IconData icon;
  final Color color;
  final String title;
  final String why;
}

class _PartnerPermissionsScreenState extends State<PartnerPermissionsScreen> with WidgetsBindingObserver {
  static const _items = [
    _Item(
      Permission.locationWhenInUse,
      Icons.location_on_rounded,
      AppColors.blue,
      'Location',
      'Pin your venue on the map with your current location, so nearby FITKEY members find you.',
    ),
    _Item(
      Permission.camera,
      Icons.photo_camera_rounded,
      AppColors.purple,
      'Camera',
      'Take photos of your venue and scan members\' QR codes at check-in.',
    ),
    _Item(
      Permission.notification,
      Icons.notifications_active_rounded,
      AppColors.primary,
      'Notifications',
      'New bookings and requests, member check-ins, listing review updates and payouts.',
    ),
  ];

  final _status = <Permission, PermissionStatus>{};
  Permission? _busy;

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

  bool _granted(Permission p) {
    final s = _status[p];
    return s != null && (s.isGranted || s.isLimited);
  }

  Future<void> _ask(_Item i) async {
    if (_status[i.permission]?.isPermanentlyDenied == true) {
      await openAppSettings();
      return;
    }
    setState(() => _busy = i.permission);
    try {
      if (i.permission == Permission.locationWhenInUse) {
        if (!await Geolocator.isLocationServiceEnabled()) await Geolocator.openLocationSettings();
        await Geolocator.requestPermission();
      } else {
        await i.permission.request();
      }
    } catch (_) {}
    if (mounted) setState(() => _busy = null);
    await _refresh();
  }

  Future<void> _allowAll() async {
    for (final i in _items) {
      if (!_granted(i.permission)) await _ask(i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allGranted = _items.every((i) => _granted(i.permission));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.onboarding ? 'Set up FITKEY Partner' : 'Permissions'),
        automaticallyImplyLeading: !widget.onboarding,
        actions: [
          if (widget.onboarding) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Skip')),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        if (widget.onboarding) ...[
          const Text('Run your business from your phone',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
          const SizedBox(height: 6),
          const Text(
            'Allow these so you can pin your venue, add photos, scan members and never miss a booking. '
            'You can change them any time in your phone settings.',
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
    final granted = _granted(i.permission);
    final blocked = _status[i.permission]?.isPermanentlyDenied == true;
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
            : FilledButton(
                onPressed: _busy == null ? () => _ask(i) : null,
                style: FilledButton.styleFrom(
                  backgroundColor: i.color,
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
                child: Text(_busy == i.permission ? '…' : (blocked ? 'Settings' : 'Allow')),
              ),
      ]),
    );
  }
}
