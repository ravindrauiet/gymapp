import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../data/fitkey_api.dart';
import '../data/models.dart';

enum SessionStatus { loading, signedOut, needsProfile, signedIn }

/// Holds the signed-in member, their active plan, and the auth token.
class Session extends ChangeNotifier {
  Session() {
    _client = ApiClient(onUnauthorized: () => signOut());
    api = FitkeyApi(_client);
  }

  static const _tokenKey = 'fitkey_token';
  final _storage = const FlutterSecureStorage();
  late final ApiClient _client;
  late final FitkeyApi api;

  SessionStatus status = SessionStatus.loading;
  User? user;
  ActiveSubscription? subscription;

  bool get hasActivePlan => subscription != null;

  Future<void> restore() async {
    String? token;
    try {
      token = await _storage.read(key: _tokenKey);
    } catch (_) {
      // The encrypted store can be unreadable after a reinstall / restore (its key isn't restored).
      // Wipe it and start signed out instead of hanging on the splash screen.
      await _storage.deleteAll().catchError((_) {});
    }
    if (token == null) {
      _set(SessionStatus.signedOut);
      return;
    }
    _client.token = token;
    try {
      await refresh();
    } on ApiException catch (e) {
      // Offline etc.: keep the token but show sign-in only if it was rejected.
      if (e.statusCode == 401) await signOut();
    } catch (_) {
      // Any other failure (e.g. unexpected data) must never leave the app stuck on the splash screen.
    }
    if (status == SessionStatus.loading) _set(SessionStatus.signedOut);
  }

  Future<void> refresh() async {
    final r = await api.me();
    user = r.user;
    subscription = r.subscription;
    _set(user!.name == null ? SessionStatus.needsProfile : SessionStatus.signedIn);
  }

  Future<String?> requestOtp(String phone) async => (await api.requestOtp(phone)).devOtp;

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
    subscription = null;
    await _storage.delete(key: _tokenKey);
    _set(SessionStatus.signedOut);
  }

  void _set(SessionStatus s) {
    status = s;
    notifyListeners();
  }
}
