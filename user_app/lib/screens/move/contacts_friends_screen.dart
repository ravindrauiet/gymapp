import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' show FlutterContacts, ContactProperty;
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/activity_api.dart';
import '../../data/wallet_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../feed/feed_profile_screen.dart';

/// Friends from your phone's contacts: who is already on FITKEY, and one-tap invites (with your referral code)
/// for everyone else. Numbers are hashed (SHA-256 of the last 10 digits) on the phone before matching.
class ContactsFriendsScreen extends StatefulWidget {
  const ContactsFriendsScreen({super.key});

  @override
  State<ContactsFriendsScreen> createState() => _ContactsFriendsScreenState();
}

class _Person {
  _Person(this.name, this.number, this.hash);
  final String name;
  final String number;
  final String hash;
}

class _ContactsFriendsScreenState extends State<ContactsFriendsScreen> {
  PermissionStatus? _perm;
  bool _loading = false;
  Object? _error;
  List<ContactMatch> _onFitkey = const [];
  List<_Person> _invite = const [];
  final _names = <String, String>{};
  String _q = '';
  String? _shareMessage;

  @override
  void initState() {
    super.initState();
    _check();
  }

  static String hashNumber(String number) {
    final digits = number.replaceAll(RegExp(r'\D'), '');
    final last10 = digits.length > 10 ? digits.substring(digits.length - 10) : digits;
    return sha256.convert(utf8.encode(last10)).toString();
  }

  Future<void> _check() async {
    final s = await Permission.contacts.status;
    setState(() => _perm = s);
    if (s.isGranted || s.isLimited) await _load();
  }

  Future<void> _allow() async {
    if (_perm?.isPermanentlyDenied == true) {
      await openAppSettings();
      return;
    }
    final s = await Permission.contacts.request();
    setState(() => _perm = s);
    if (s.isGranted || s.isLimited) await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<Session>().api;
      final contacts = await FlutterContacts.getAll(properties: {ContactProperty.phone});
      final byHash = <String, _Person>{};
      for (final c in contacts) {
        for (final ph in c.phones) {
          final digits = ph.number.replaceAll(RegExp(r'\D'), '');
          if (digits.length < 10) continue;
          final h = hashNumber(ph.number);
          byHash.putIfAbsent(h, () => _Person(c.displayName?.trim().isNotEmpty == true ? c.displayName!.trim() : ph.number, ph.number, h));
        }
      }
      final hashes = byHash.keys.toList();
      final matches = <ContactMatch>[];
      for (var i = 0; i < hashes.length; i += 3000) {
        matches.addAll(await api.matchContacts(hashes.sublist(i, i + 3000 > hashes.length ? hashes.length : i + 3000)));
      }
      final matched = {for (final m in matches) m.hash};
      for (final m in matches) {
        _names[m.id] = byHash[m.hash]?.name ?? m.name ?? 'Friend';
      }
      try {
        _shareMessage = (await api.referrals()).shareMessage;
      } catch (_) {}
      final invite = byHash.values.where((p) => !matched.contains(p.hash)).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _onFitkey = matches;
        _invite = invite;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendInvite(_Person p) async {
    final msg = _shareMessage ?? 'Join me on FITKEY — one app for gyms, studios, steps and more! https://play.google.com/store/apps/details?id=com.fitkey.fitkey_user';
    try {
      await SharePlus.instance.share(ShareParams(text: 'Hey ${p.name.split(' ').first}! $msg', subject: 'Join me on FITKEY'));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final granted = _perm != null && (_perm!.isGranted || _perm!.isLimited);
    return Scaffold(
      appBar: AppBar(title: const Text('Friends from contacts')),
      body: _perm == null
          ? const Center(child: CircularProgressIndicator())
          : !granted
              ? EmptyView(
                  icon: Icons.contacts_rounded,
                  color: AppColors.purple,
                  title: 'Find your friends on FITKEY',
                  message: 'Allow contacts to see who already works out with FITKEY. Numbers are scrambled on your '
                      'phone before matching and your contact list is never stored.',
                  action: SizedBox(
                    width: 220,
                    child: AppButton(
                      label: _perm!.isPermanentlyDenied ? 'Open settings' : 'Allow contacts',
                      color: AppColors.purple,
                      onPressed: _allow,
                    ),
                  ),
                )
              : _loading
                  ? const SkeletonList()
                  : _error != null
                      ? ErrorView(error: _error!, onRetry: _load)
                      : RefreshIndicator(onRefresh: _load, child: _list()),
    );
  }

  Widget _list() {
    final q = _q.toLowerCase();
    final invite = q.isEmpty ? _invite : _invite.where((p) => p.name.toLowerCase().contains(q)).toList();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
      SectionTitle('On FITKEY', subtitle: '${_onFitkey.length} of your contacts', padding: const EdgeInsets.fromLTRB(0, 8, 0, 12)),
      if (_onFitkey.isEmpty)
        const AppCard(
          child: Text('None of your contacts are on FITKEY yet — invite them below and earn coins when they join.',
              style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w500)),
        ),
      for (final m in _onFitkey) ...[
        AppCard(
          padding: const EdgeInsets.all(12),
          onTap: () => push(context, FeedProfileScreen(userId: m.id)),
          child: Row(children: [
            PersonAvatar(name: _names[m.id] ?? m.name, photoUrl: m.avatarUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_names[m.id] ?? m.name ?? 'Friend', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                if (m.city != null)
                  Text(m.city!, style: const TextStyle(color: AppColors.text3, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ]),
            ),
            const Tag('On FITKEY', color: AppColors.green),
          ]),
        ),
        const SizedBox(height: 10),
      ],
      SectionTitle('Invite', subtitle: 'They get FITKEY, you earn referral coins'),
      TextField(
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Search contacts'),
        onChanged: (v) => setState(() => _q = v),
      ),
      const SizedBox(height: 10),
      for (final p in invite.take(300))
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: PersonAvatar(name: p.name, size: 40),
          title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(p.number),
          trailing: OutlinedButton(
            onPressed: () => _sendInvite(p),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 14)),
            child: const Text('Invite'),
          ),
        ),
    ]);
  }
}
