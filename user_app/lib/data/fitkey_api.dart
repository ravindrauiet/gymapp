import 'package:fitkey_core/fitkey_core.dart';
import 'models.dart';

/// All member-facing endpoints of the FITKEY API.
class FitkeyApi {
  FitkeyApi(this._client);

  final ApiClient _client;

  // ---- Auth & profile -------------------------------------------------------
  Future<({String? devOtp})> requestOtp(String phone) async {
    final r = await _client.post('/auth/otp/request', {'phone': phone, 'role': 'user'});
    return (devOtp: r['devOtp'] as String?);
  }

  Future<({String token, User user, bool isNewUser})> verifyOtp(String phone, String otp) async {
    final r = await _client.post('/auth/otp/verify', {'phone': phone, 'otp': otp, 'role': 'user'});
    return (token: r['token'] as String, user: User.fromJson(r['user']), isNewUser: r['isNewUser'] == true);
  }

  Future<({User user, ActiveSubscription? subscription})> me() async {
    final r = await _client.get('/me');
    final sub = r['activeSubscription'];
    return (user: User.fromJson(r['user']), subscription: sub == null ? null : ActiveSubscription.fromJson(sub));
  }

  Future<User> updateProfile(Json fields) async => User.fromJson((await _client.patch('/me', fields))['user']);

  Future<List<String>> cities() async => List<String>.from((await _client.get('/meta'))['cities'] as List);

  // ---- Plans ----------------------------------------------------------------
  Future<List<Plan>> plans() async =>
      ((await _client.get('/plans'))['plans'] as List).map((p) => Plan.fromJson(p)).toList();

  Future<List<VenueSummary>> planVenues(String planId) async =>
      ((await _client.get('/plans/$planId/venues'))['venues'] as List).map((v) => VenueSummary.fromJson(v)).toList();

  Future<List<Subscription>> mySubscriptions() async => ((await _client.get('/subscriptions/me'))['subscriptions'] as List)
      .map((s) => Subscription.fromJson(s))
      .toList();

  Future<void> buyPlan(String planId) => _client.post('/subscriptions', {'planId': planId});

  // ---- Venues ---------------------------------------------------------------
  Future<List<VenueSummary>> venues({String? category, String? city, String? q, int limit = 20, int page = 1}) async {
    final r = await _client.get('/venues', query: {'category': category, 'city': city, 'q': q, 'limit': limit, 'page': page});
    return (r['venues'] as List).map((v) => VenueSummary.fromJson(v)).toList();
  }

  Future<({Venue venue, List<PlanRef> plans})> venue(String id) async {
    final r = await _client.get('/venues/$id');
    return (
      venue: Venue.fromJson(r['venue']),
      plans: (r['plans'] as List).map((p) => PlanRef.fromJson(p)).toList(),
    );
  }

  // ---- Check-in -------------------------------------------------------------
  Future<Checkin> checkinWithQr(String qr) async => Checkin.fromJson((await _client.post('/checkins', {'qr': qr}))['checkin']);

  Future<Checkin> checkinWithOtp(String venueId, String otp) async =>
      Checkin.fromJson((await _client.post('/checkins', {'venueId': venueId, 'otp': otp}))['checkin']);

  Future<List<Checkin>> myCheckins({int page = 1}) async =>
      ((await _client.get('/checkins/me', query: {'page': page, 'limit': 30}))['checkins'] as List)
          .map((c) => Checkin.fromJson(c))
          .toList();

  // ---- FitKey Studio --------------------------------------------------------
  Future<List<VideoCategoryCount>> videoCategories() async =>
      ((await _client.get('/videos/categories'))['categories'] as List).map((c) => VideoCategoryCount.fromJson(c)).toList();

  Future<List<Video>> videos({String? category, int limit = 30}) async =>
      ((await _client.get('/videos', query: {'category': category, 'limit': limit}))['videos'] as List)
          .map((v) => Video.fromJson(v))
          .toList();

  // ---- Buddy ----------------------------------------------------------------
  Future<List<BuddyPost>> myBuddyPosts() async =>
      ((await _client.get('/buddy/posts/me'))['posts'] as List).map((p) => BuddyPost.fromJson(p)).toList();

  Future<String> createBuddyPost({
    required String venueId,
    required String slotDate,
    required String slotStart,
    required String slotEnd,
    String? note,
  }) async {
    final r = await _client.post('/buddy/posts', {
      'venueId': venueId,
      'slotDate': slotDate,
      'slotStart': slotStart,
      'slotEnd': slotEnd,
      if (note != null && note.isNotEmpty) 'note': note,
    });
    return r['post']['id'] as String;
  }

  Future<void> deleteBuddyPost(String id) => _client.delete('/buddy/posts/$id');

  Future<List<BuddyMatch>> buddyMatches(String postId) async =>
      ((await _client.get('/buddy/posts/$postId/matches'))['matches'] as List).map((m) => BuddyMatch.fromJson(m)).toList();

  Future<void> sendBuddyRequest(String fromPostId, String toPostId) =>
      _client.post('/buddy/requests', {'fromPostId': fromPostId, 'toPostId': toPostId});

  Future<List<BuddyRequest>> buddyRequests() async =>
      ((await _client.get('/buddy/requests'))['requests'] as List).map((r) => BuddyRequest.fromJson(r)).toList();

  Future<void> respondBuddyRequest(String id, {required bool accept}) =>
      _client.patch('/buddy/requests/$id', {'status': accept ? 'accepted' : 'declined'});

  Future<List<ChatMessage>> messages(String requestId, {String? after}) async =>
      ((await _client.get('/buddy/requests/$requestId/messages', query: {'after': after}))['messages'] as List)
          .map((m) => ChatMessage.fromJson(m))
          .toList();

  Future<ChatMessage> sendMessage(String requestId, String body) async =>
      ChatMessage.fromJson((await _client.post('/buddy/requests/$requestId/messages', {'body': body}))['message']);

  Future<void> blockUser(String userId) => _client.post('/buddy/block', {'userId': userId});

  Future<void> reportUser(String userId, String reason) =>
      _client.post('/buddy/report', {'userId': userId, 'reason': reason});

  // ---- Contests & leaderboard ----------------------------------------------
  Future<List<Contest>> contests({String status = 'active'}) async =>
      ((await _client.get('/contests', query: {'status': status}))['contests'] as List)
          .map((c) => Contest.fromJson(c))
          .toList();

  Future<({Contest contest, Leaderboard leaderboard})> contest(String id, {String? city}) async {
    final r = await _client.get('/contests/$id', query: {'city': city});
    return (contest: Contest.fromJson(r['contest']), leaderboard: Leaderboard.fromJson(r['leaderboard']));
  }

  Future<void> joinContest(String id) => _client.post('/contests/$id/join');

  Future<Leaderboard> leaderboard({required String period, String? city}) async =>
      Leaderboard.fromJson(await _client.get('/leaderboard', query: {'period': period, 'city': city}));

  // ---- Health ---------------------------------------------------------------
  Future<HealthReport> healthReport({int days = 30}) async =>
      HealthReport.fromJson(await _client.get('/health/report', query: {'days': days}));

  Future<void> logWeight(double kg) => _client.post('/health/weights', {'weightKg': kg});

  Future<void> logActivity(Json activity) => _client.post('/health/activities', activity);

  Future<List<Activity>> activities() async =>
      ((await _client.get('/health/activities', query: {'limit': 50}))['activities'] as List)
          .map((a) => Activity.fromJson(a))
          .toList();

  Future<void> deleteActivity(String id) => _client.delete('/health/activities/$id');
}
