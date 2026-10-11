import 'package:fitkey_core/fitkey_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/models.dart';
import '../data/partner_api.dart';

enum SessionStatus { loading, signedOut, needsProfile, signedIn }

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
    final token = await _storage.read(key: _tokenKey);
    if (token == null) return _set(SessionStatus.signedOut);
    _client.token = token;
    try {
      await refresh();
    } on ApiException catch (e) {
      if (e.statusCode == 401) await signOut();
      if (status == SessionStatus.loading) _set(SessionStatus.signedOut);
    }
  }

  Future<void> refresh() async {
    user = await api.me();
    _set(user!.name == null || user!.email == null ? SessionStatus.needsProfile : SessionStatus.signedIn);
  }

  Future<String?> requestOtp(String phone) => api.requestOtp(phone);

  Future<void> verifyOtp(String phone, String otp) async {
    final r = await api.verifyOtp(phone, otp);
    _client.token = r.token;
    await _storage.write(key: _tokenKey, value: r.token);
    await refresh();
  }

  Future<void> updateProfile(Json fields) async {
    user = await api.updateProfile(fields);
    _set(SessionStatus.signedIn);
  }

  Future<void> signOut() async {
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
