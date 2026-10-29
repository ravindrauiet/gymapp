import 'dart:math';

import 'package:android_play_install_referrer/android_play_install_referrer.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'fitkey_api.dart';
import 'models.dart';

/// FitKey Coins balances. Coins can't be spent yet — the app shows balance and history only.
class CoinWallet {
  CoinWallet.fromJson(Json j)
      : available = (j['available'] as num).toInt(),
        locked = (j['locked'] as num).toInt(),
        totalEarned = (j['totalEarned'] as num).toInt(),
        referralCoins = (j['referralCoins'] as num? ?? 0).toInt(),
        hasPass = j['hasPass'] == true;

  final int available;

  /// Welcome coins that unlock with the member's first FitKey Pass.
  final int locked;
  final int totalEarned;
  final int referralCoins;
  final bool hasPass;
}

class CoinEntry {
  CoinEntry.fromJson(Json j)
      : id = j['id'],
        amount = (j['amount'] as num).toInt(),
        kind = j['kind'],
        locked = j['status'] == 'locked',
        title = j['title'] ?? 'Coins',
        subtitle = j['subtitle'],
        createdAt = DateTime.parse(j['createdAt']).toLocal();

  final String id;
  final int amount;

  /// welcome_bonus | plan_purchase | referral_reward | …
  final String kind;
  final bool locked;
  final String title;
  final String? subtitle;
  final DateTime createdAt;
}

class Referral {
  Referral.fromJson(Json j)
      : id = j['id'],
        name = j['name'] ?? 'FitKey member',
        avatarUrl = j['avatarUrl'],
        passBought = j['status'] == 'pass_bought',
        joinedAt = DateTime.parse(j['joinedAt']).toLocal(),
        coins = (j['coins'] as num? ?? 0).toInt();

  final String id;

  /// Masked by the server, e.g. "Rahul S."
  final String name;
  final String? avatarUrl;
  final bool passBought;
  final DateTime joinedAt;
  final int coins;
}

class ReferralInfo {
  ReferralInfo.fromJson(Json j)
      : code = j['code'],
        shareLink = j['shareLink'],
        shareMessage = j['shareMessage'],
        rewardPerReferral = (j['rewardPerReferral'] as num).toInt(),
        invited = (j['stats']['invited'] as num).toInt(),
        passBought = (j['stats']['passBought'] as num).toInt(),
        coinsEarned = (j['stats']['coinsEarned'] as num).toInt(),
        referrals = (j['referrals'] as List).map((r) => Referral.fromJson(r)).toList(),
        referredBy = (j['referredBy'] as Map?)?['name'] as String?,
        canApplyCode = j['canApplyCode'] == true;

  final String code;
  final String shareLink;
  final String shareMessage;
  final int rewardPerReferral;
  final int invited;
  final int passBought;
  final int coinsEarned;
  final List<Referral> referrals;

  /// Masked name of whoever invited this member, if anyone.
  final String? referredBy;
  final bool canApplyCode;
}

/// Coins credited by a pass purchase (POST /subscriptions → `coins`).
class PurchaseCoins {
  PurchaseCoins.fromJson(Json j)
      : earned = (j['earned'] as num? ?? 0).toInt(),
        unlocked = (j['unlocked'] as num? ?? 0).toInt(),
        available = (j['available'] as num? ?? 0).toInt();

  final int earned;
  final int unlocked;
  final int available;
}

extension WalletApi on FitkeyApi {
  Future<({CoinWallet wallet, List<CoinEntry> ledger})> wallet() async {
    final r = await client.get('/wallet');
    return (
      wallet: CoinWallet.fromJson(r['wallet']),
      ledger: (r['ledger'] as List).map((e) => CoinEntry.fromJson(e)).toList(),
    );
  }

  Future<ReferralInfo> referrals() async => ReferralInfo.fromJson(await client.get('/wallet/referrals'));

  /// Applies a friend's code (new members only). Returns the server's confirmation message.
  /// Throws an ApiException with a member-friendly message when the code can't be used.
  Future<String> applyReferralCode(String code) async {
    final deviceId = await DeviceIdentity.id();
    final r = await client.post('/wallet/referral/apply', {'code': code.trim().toUpperCase(), 'deviceId': ?deviceId});
    return r['message'] as String? ?? 'Referral code applied';
  }

  /// Best-effort: remembers this phone against the account (used to block duplicate-device referrals).
  Future<void> registerDevice() async {
    final deviceId = await DeviceIdentity.id();
    if (deviceId == null) return;
    await client.post('/wallet/device', {'deviceId': deviceId});
  }
}

/// A stable per-install identifier for referral anti-abuse. Mobile only; null on web.
///
/// Android has no public hardware id any more, so we keep a random id in secure storage (survives logouts, reset on
/// reinstall). iOS uses identifierForVendor.
class DeviceIdentity {
  static const _key = 'fitkey_device_id';
  static String? _cached;

  static Future<String?> id() async {
    if (kIsWeb) return null;
    if (_cached != null) return _cached;
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final ios = await DeviceInfoPlugin().iosInfo;
        if (ios.identifierForVendor != null) return _cached = 'ios:${ios.identifierForVendor}';
      }
      const storage = FlutterSecureStorage();
      var id = await storage.read(key: _key);
      if (id == null) {
        final rnd = Random.secure();
        id = List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
        await storage.write(key: _key, value: id);
      }
      var prefix = 'dev';
      if (defaultTargetPlatform == TargetPlatform.android) {
        final a = await DeviceInfoPlugin().androidInfo;
        prefix = 'and:${a.brand}-${a.model}'.replaceAll(RegExp(r'[^A-Za-z0-9:_-]'), '');
      }
      final full = '$prefix:$id';
      return _cached = full.length > 128 ? full.substring(full.length - 128) : full;
    } catch (_) {
      return null;
    }
  }
}

/// Reads the referral code from the Play Store install referrer (Android only), e.g. a link
/// `…/details?id=com.fitkey.fitkey_user&referrer=FK7QX2M9`. Returns null when there is none.
Future<String?> installReferralCode() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final details = await AndroidPlayInstallReferrer.installReferrer;
    final raw = Uri.decodeComponent(details.installReferrer ?? '').trim();
    if (raw.isEmpty) return null;
    final codeRe = RegExp(r'^[A-Za-z0-9]{4,12}$');
    if (codeRe.hasMatch(raw) && raw.toUpperCase().startsWith('FK')) return raw.toUpperCase();
    // Also accept "code=FK…" / "ref=FK…" style referrer strings; organic installs ("utm_source=google-play…") give null.
    final params = Uri.splitQueryString(raw);
    for (final k in const ['code', 'ref', 'referrer', 'referral']) {
      final v = params[k];
      if (v != null && codeRe.hasMatch(v)) return v.toUpperCase();
    }
  } catch (_) {
    // Not installed from Play / service unavailable.
  }
  return null;
}
