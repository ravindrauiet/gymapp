import 'dart:math';

import 'package:android_play_install_referrer/android_play_install_referrer.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'fitkey_api.dart';
import 'models.dart';

int _i(dynamic v) => v == null ? 0 : (v as num).toInt();
DateTime? _d(dynamic v) => v == null ? null : DateTime.parse(v as String).toLocal();

/// Business rules the server enforces (admin-editable).
class WalletRules {
  WalletRules.fromJson(Json j)
      : storeMaxCoinPct = _i(j['storeMaxCoinPct'] ?? 50),
        passMaxCoinPct = _i(j['passMaxCoinPct'] ?? 50),
        referralReward = _i(j['referralReward'] ?? 100);

  final int storeMaxCoinPct;
  final int passMaxCoinPct;
  final int referralReward;
}

/// All balances of the member (BRD §3/§4). 1 coin = ₹1.
///  - FitKey coins: bought in coin packs; the only coins that pay for visits.
///  - Sessions: from session plans, 1 per visit at any centre.
///  - Referral coins: welcome + referral rewards; locked until the first FitKey pass; Store + pass checkout.
///  - ProveIt coins: earned in ProveIt; Store only.
class CoinWallet {
  CoinWallet.fromJson(Json j)
      : fitkeyCoins = _i(j['fitkey']?['balance']),
        fitkeyExpiresAt = _d(j['fitkey']?['expiresAt']),
        sessionsLeft = _i(j['sessions']?['left']),
        sessionsExpiresAt = _d(j['sessions']?['expiresAt']),
        sessionPlans = ((j['sessions']?['plans'] as List?) ?? const []).map((e) => PassPurchase.fromJson(e)).toList(),
        referralCoins = _i(j['referral']?['available']),
        referralLocked = _i(j['referral']?['locked']),
        proveitCoins = _i(j['proveit']?['available']),
        legacyPassName = j['legacyPass']?['name'],
        legacyPassEndsAt = _d(j['legacyPass']?['endsAt']),
        hasPass = j['hasPass'] == true,
        rules = WalletRules.fromJson((j['rules'] as Map?)?.cast<String, dynamic>() ?? const {});

  final int fitkeyCoins;
  final DateTime? fitkeyExpiresAt;
  final int sessionsLeft;
  final DateTime? sessionsExpiresAt;
  final List<PassPurchase> sessionPlans;
  final int referralCoins;

  /// Referral-type coins (welcome bonus, referral rewards) waiting for a FitKey pass purchase.
  final int referralLocked;
  final int proveitCoins;
  final String? legacyPassName;
  final DateTime? legacyPassEndsAt;
  final bool hasPass;
  final WalletRules rules;

  /// Coins usable in the Store (ProveIt + active referral).
  int get storeCoins => proveitCoins + referralCoins;
}

class CoinEntry {
  CoinEntry.fromJson(Json j)
      : id = j['id'],
        amount = (j['amount'] as num).toInt(),
        kind = j['kind'],
        wallet = j['wallet'] ?? 'referral',
        locked = j['status'] == 'locked',
        title = j['title'] ?? 'Coins',
        subtitle = j['subtitle'],
        createdAt = DateTime.parse(j['createdAt']).toLocal();

  final String id;
  final int amount;

  /// welcome_bonus | referral_signup | referral_reward | proveit | pack_purchase | visit | visit_refund |
  /// store_redemption | pass_redemption | plan_purchase (legacy) | …
  final String kind;

  /// fitkey | referral | proveit
  final String wallet;
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
        coins = (j['coins'] as num? ?? 0).toInt(),
        locked = j['locked'] == true;

  final String id;

  /// Masked by the server, e.g. "Rahul S."
  final String name;
  final String? avatarUrl;
  final bool passBought;
  final DateTime joinedAt;
  final int coins;

  /// The reward is credited but waits for the friend's first FitKey pass.
  final bool locked;
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
        coinsLocked = (j['stats']['coinsLocked'] as num? ?? 0).toInt(),
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
  final int coinsLocked;
  final List<Referral> referrals;

  /// Masked name of whoever invited this member, if anyone.
  final String? referredBy;
  final bool canApplyCode;
}

/// A coin pack: pay ₹ → get FitKey coins for visits.
class CoinPack {
  CoinPack.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        description = j['description'],
        pricePaise = _i(j['pricePaise']),
        coins = _i(j['coins']),
        bonusCoins = _i(j['bonusCoins']),
        validityDays = _i(j['validityDays']);

  final String id;
  final String name;
  final String? description;
  final int pricePaise;
  final int coins;
  final int bonusCoins;
  final int validityDays;
}

/// A session plan: N visits within the validity, 1 session per visit at any centre.
class SessionPlan {
  SessionPlan.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        description = j['description'],
        pricePaise = _i(j['pricePaise']),
        sessions = _i(j['sessions']),
        validityDays = _i(j['validityDays']),
        perSessionPaise = _i(j['perSessionPaise']);

  final String id;
  final String name;
  final String? description;
  final int pricePaise;
  final int sessions;
  final int validityDays;
  final int perSessionPaise;
}

class CategoryCost {
  CategoryCost.fromJson(Json j)
      : category = j['category'],
        coins = _i(j['coins']);
  final String category;
  final int coins;
}

class PassCatalog {
  PassCatalog.fromJson(Json j)
      : coinPacks = (j['coinPacks'] as List).map((e) => CoinPack.fromJson(e)).toList(),
        sessionPlans = (j['sessionPlans'] as List).map((e) => SessionPlan.fromJson(e)).toList(),
        categoryCosts = (j['categoryCosts'] as List).map((e) => CategoryCost.fromJson(e)).toList(),
        rules = WalletRules.fromJson(j['rules']);

  final List<CoinPack> coinPacks;
  final List<SessionPlan> sessionPlans;
  final List<CategoryCost> categoryCosts;
  final WalletRules rules;
}

/// One FitKey pass purchase (coin pack or session plan).
class PassPurchase {
  PassPurchase.fromJson(Json j)
      : id = j['id'],
        kind = j['kind'],
        name = j['name'],
        pricePaise = _i(j['pricePaise']),
        coinsRedeemed = _i(j['coinsRedeemed']),
        paidPaise = _i(j['paidPaise']),
        coins = _i(j['coins']),
        coinsRemaining = _i(j['coinsRemaining']),
        sessionsTotal = _i(j['sessionsTotal']),
        sessionsLeft = _i(j['sessionsLeft']),
        state = j['state'] ?? 'active',
        expiresAt = DateTime.parse(j['expiresAt']).toLocal(),
        createdAt = DateTime.parse(j['createdAt']).toLocal();

  final String id;

  /// coin_pack | session_plan
  final String kind;
  final String name;
  final int pricePaise;
  final int coinsRedeemed;
  final int paidPaise;
  final int coins;
  final int coinsRemaining;
  final int sessionsTotal;
  final int sessionsLeft;

  /// active | used | expired
  final String state;
  final DateTime expiresAt;
  final DateTime createdAt;

  bool get isCoinPack => kind == 'coin_pack';
}

/// Result of POST /wallet/passes.
class PassPurchaseResult {
  PassPurchaseResult.fromJson(Json j)
      : purchase = PassPurchase.fromJson(j['purchase']),
        coinsUsed = _i(j['coinsUsed']),
        paidPaise = _i(j['paidPaise']),
        coinsActivated = _i(j['coinsActivated']),
        referralActivated = j['referralActivated'] == true;

  final PassPurchase purchase;
  final int coinsUsed;
  final int paidPaise;

  /// Referral-type coins (welcome / referral reward) that this purchase made active.
  final int coinsActivated;
  final bool referralActivated;
}

/// GET /wallet/low-balance
class LowBalance {
  LowBalance.fromJson(Json j)
      : low = j['low'] == true,
        kind = j['kind'],
        title = j['title'],
        message = j['message'],
        sessionsLeft = _i(j['sessionsLeft']),
        coins = _i(j['coins']);

  final bool low;

  /// sessions | coins
  final String? kind;
  final String? title;
  final String? message;
  final int sessionsLeft;
  final int coins;
}

/// Coins usable on an amount (server-side caps): Store = ProveIt first then referral; pass = referral only.
class Redeemable {
  Redeemable.fromJson(Json j)
      : maxPct = _i(j['maxPct']),
        maxCoins = _i(j['maxCoins']),
        proveit = _i(j['proveit']),
        referral = _i(j['referral']),
        coins = _i(j['coins']),
        referralLocked = _i(j['referralLocked']);

  final int maxPct;
  final int maxCoins;
  final int proveit;
  final int referral;
  final int coins;
  final int referralLocked;
}

/// What a visit to a venue would cost now (no charge).
class VisitCost {
  VisitCost.fromJson(Json j)
      : method = j['method'],
        amount = _i(j['amount']),
        label = j['label'] ?? '',
        sufficient = j['sufficient'] == true,
        coinCost = _i(j['coinCost']);

  /// session | coins | legacy_pass | null (no pass at all)
  final String? method;
  final int amount;
  final String label;
  final bool sufficient;
  final int coinCost;
}

extension WalletApi on FitkeyApi {
  Future<({CoinWallet wallet, List<CoinEntry> ledger})> wallet() async {
    final r = await client.get('/wallet');
    return (
      wallet: CoinWallet.fromJson(r['wallet']),
      ledger: (r['ledger'] as List).map((e) => CoinEntry.fromJson(e)).toList(),
    );
  }

  Future<PassCatalog> passCatalog() async => PassCatalog.fromJson(await client.get('/wallet/catalog'));

  Future<List<PassPurchase>> passPurchases() async =>
      ((await client.get('/wallet/purchases'))['purchases'] as List).map((e) => PassPurchase.fromJson(e)).toList();

  Future<LowBalance> lowBalance() async => LowBalance.fromJson(await client.get('/wallet/low-balance'));

  Future<VisitCost> visitCost(String venueId) async =>
      VisitCost.fromJson((await client.get('/wallet/visit-cost/$venueId'))['cost']);

  /// [context] is 'store' or 'pass'.
  Future<Redeemable> redeemable(String context, int amountPaise) async => Redeemable.fromJson(
      (await client.get('/wallet/redeemable', query: {'context': context, 'amountPaise': '$amountPaise'}))['redeemable']);

  /// Buys a coin pack ([kind] 'coin_pack') or a session plan ('session_plan'). Demo payments: activates instantly.
  Future<PassPurchaseResult> buyPass({required String kind, required String id, bool useCoins = false}) async =>
      PassPurchaseResult.fromJson(await client.post('/wallet/passes', {'kind': kind, 'id': id, 'useCoins': useCoins}));

  /// Store checkout with optional coin redemption (ProveIt first, then referral, max 50% — enforced by the server).
  Future<({MarketplaceOrder order, int coinsRedeemed, int payablePaise})> placeStoreOrder({
    required List<({String productId, int quantity})> items,
    required Json shippingAddress,
    required String paymentMethod,
    bool useCoins = false,
  }) async {
    final r = await client.post('/marketplace/orders', {
      'items': items.map((i) => {'productId': i.productId, 'quantity': i.quantity}).toList(),
      'shippingAddress': shippingAddress,
      'paymentMethod': paymentMethod,
      'useCoins': useCoins,
    });
    final o = r['order'] as Json;
    final order = MarketplaceOrder.fromJson(o);
    return (
      order: order,
      coinsRedeemed: _i(o['coins_redeemed'] ?? o['coinsRedeemed']),
      payablePaise: _i(o['payable_paise'] ?? o['payablePaise'] ?? order.totalAmountPaise),
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
