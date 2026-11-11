import 'package:fitkey_core/fitkey_core.dart' show ApiClient, ApiException;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/brd_api.dart';
import '../data/models.dart';
import '../data/partner_api.dart';

/// Onboarding order after login (Partner BRD §2): needsPartnerType ("What are you joining as?") → needsProfile
/// (About you: name, business email, city) → signedIn.
enum SessionStatus { loading, signedOut, needsProfile, needsPartnerType, signedIn }

/// Signed-in venue owner + auth token. Uses its own storage key so the member app's login is separate.
class PartnerSession extends ChangeNotifier {
  PartnerSession() {
    _client = ApiClient(onUnauthorized: () => signOut());
    api = PartnerApi(_client);
  }

  static const _tokenKey = 'fitkey_partner_token';
  final _storage = const FlutterSecureStorage();
  late final ApiClient _client;
  late final PartnerApi api;

  SessionStatus status = SessionStatus.loading;
  PartnerUser? user;

  Future<void> restore() async {
    String? token;
    try {
      token = await _storage.read(key: _tokenKey);
    } catch (_) {
      // The encrypted store can be unreadable after a reinstall / restore; wipe it and start signed out.
      await _storage.deleteAll().catchError((_) {});
    }
    if (token == null) return _set(SessionStatus.signedOut);
    _client.token = token;
    try {
      await refresh();
    } catch (e) {
      // 401 → token is dead, forget it. Anything else (offline, server down): show login but keep the token
      // stored so the next launch can restore the session.
      if (e is ApiException && e.statusCode == 401) await signOut();
      if (status == SessionStatus.loading) _set(SessionStatus.signedOut);
    }
  }

  Future<void> refresh() async {
    user = await api.me();
    _set(_statusFor(user!));
  }

  /// FitKey staff accounts (not acting for a partner) skip onboarding; everyone else answers the partner type
  /// first, then About you.
  SessionStatus _statusFor(PartnerUser u) {
    if (u.isFitkeyStaff && !isActingAsPartner) return SessionStatus.signedIn;
    if (u.partnerType == null) return SessionStatus.needsPartnerType;
    if ((u.name ?? '').trim().isEmpty || (u.email ?? '').trim().isEmpty) return SessionStatus.needsProfile;
    return SessionStatus.signedIn;
  }

  /// Lets a new partner go back from About you to change what they are joining as.
  void changePartnerType() {
    if (status == SessionStatus.needsProfile) _set(SessionStatus.needsPartnerType);
  }

  // ---- Assisted listing (BRD §8): a FitKey employee acts as a partner with a scoped token -------------------

  String? _staffToken;
  PartnerUser? _staffUser;

  /// True while a FitKey employee is listing on behalf of a partner.
  bool get isActingAsPartner => _staffToken != null;

  /// The employee's own account while acting (null otherwise).
  PartnerUser? get staffUser => _staffUser;

  /// Switches API calls to [actAsToken] (from POST /partner/staff/partners). Not persisted: a restart returns to
  /// the employee's own account.
  Future<void> startActingAs(String actAsToken) async {
    _staffToken ??= _client.token;
    _staffUser ??= user;
    _client.token = actAsToken;
    user = await api.me();
    _set(SessionStatus.signedIn);
  }

  /// Back to the employee's own account.
  Future<void> stopActing() async {
    if (_staffToken == null) return;
    _client.token = _staffToken;
    _staffToken = null;
    _staffUser = null;
    await refresh();
  }

  Future<String?> requestOtp(String phone) => api.requestOtp(phone);

  Future<void> verifyOtp(String phone, String otp) async {
    final r = await api.verifyOtp(phone, otp);
    _client.token = r.token;
    await _storage.write(key: _tokenKey, value: r.token);
    await refresh();
  }

  /// Saves name / email / city via PUT /partner/profile (contract §A); falls back to PATCH /me on older servers.
  Future<void> updateProfile(Json fields) async {
    try {
      user = await api.updatePartnerProfile(
        name: fields['name'] as String?,
        email: fields['email'] as String?,
        city: fields['city'] as String?,
      );
    } on ApiException catch (e) {
      if (e.statusCode != 404) rethrow;
      user = await api.updateProfile(fields);
    }
    _set(_statusFor(user!));
  }

  /// Saves the partner type chosen on "What are you joining as?".
  Future<void> setPartnerType(String partnerType) async {
    await api.updatePartnerProfile(partnerType: partnerType);
    await refresh();
  }

  Future<void> signOut() async {
    _staffToken = null;
    _staffUser = null;
    _client.token = null;
    user = null;
    await _storage.delete(key: _tokenKey);
    _set(SessionStatus.signedOut);
  }

  void _set(SessionStatus s) {
    status = s;
    notifyListeners();
  }
}
