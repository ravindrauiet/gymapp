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

  // ---- Goals & Profiling ---------------------------------------------------
  Future<UserGoal?> goal() async {
    final r = await _client.get('/goals');
    final g = r['goal'];
    return g == null ? null : UserGoal.fromJson(g);
  }

  Future<UserGoal> saveGoal(Json fields) async {
    final r = await _client.post('/goals', fields);
    return UserGoal.fromJson(r['goal']);
  }

  // ---- Marketplace / Store --------------------------------------------------
  Future<List<MarketplaceProduct>> marketplaceProducts({String? category, String? q, int page = 1}) async {
    final r = await _client.get('/marketplace/products', query: {'category': category, 'q': q, 'page': page});
    return (r['products'] as List).map((p) => MarketplaceProduct.fromJson(p)).toList();
  }

  Future<MarketplaceProduct> marketplaceProduct(String id) async {
    final r = await _client.get('/marketplace/products/$id');
    return MarketplaceProduct.fromJson(r['product']);
  }

  Future<MarketplaceOrder> createMarketplaceOrder({
    required List<({String productId, int quantity})> items,
    required Json shippingAddress,
    required String paymentMethod,
  }) async {
    final payload = {
      'items': items.map((i) => {'productId': i.productId, 'quantity': i.quantity}).toList(),
      'shippingAddress': shippingAddress,
      'paymentMethod': paymentMethod,
    };
    final r = await _client.post('/marketplace/orders', payload);
    return MarketplaceOrder.fromJson(r['order']);
  }

  Future<List<MarketplaceOrder>> myMarketplaceOrders() async {
    final r = await _client.get('/marketplace/orders/me');
    return (r['orders'] as List).map((o) => MarketplaceOrder.fromJson(o)).toList();
  }

  Future<({MarketplaceOrder order, List<Json> timeline})> marketplaceOrder(String id) async {
    final r = await _client.get('/marketplace/orders/$id');
    return (
      order: MarketplaceOrder.fromJson(r['order']),
      timeline: List<Json>.from(r['timeline'] as List),
    );
  }

  // ---- Fuel Log (Nutrition) -------------------------------------------------
  Future<List<FoodItem>> foodEncyclopedia({String? q, String? category}) async {
    final r = await _client.get('/nutrition/foods', query: {'q': q, 'category': category});
    return (r['foods'] as List).map((f) => FoodItem.fromJson(f)).toList();
  }

  Future<FoodItem> foodItemDetails(String id) async {
    final r = await _client.get('/nutrition/foods/$id');
    return FoodItem.fromJson(r['food']);
  }

  Future<MealDailySummary> dailyMeals({String? date}) async {
    final r = await _client.get('/nutrition/meals', query: {'date': date});
    return MealDailySummary.fromJson(r);
  }

  Future<MealLog> logMeal(Json meal) async {
    final r = await _client.post('/nutrition/meals', meal);
    return MealLog.fromJson(r['meal']);
  }

  Future<void> deleteMeal(String id) => _client.delete('/nutrition/meals/$id');

  Future<({bool found, FoodItem? food, String barcode})> lookupBarcode(String barcode) async {
    final r = await _client.get('/nutrition/barcode/$barcode');
    final found = r['found'] == true;
    return (
      found: found,
      food: found && r['food'] != null ? FoodItem.fromJson(r['food']) : null,
      barcode: barcode,
    );
  }

  Future<FoodItem> registerBarcodeFood(Json fields) async {
    final r = await _client.post('/nutrition/barcode/register', fields);
    return FoodItem.fromJson(r['food']);
  }

  // ---- Movement & Step Tracker ----------------------------------------------
  Future<void> syncSteps({required int steps, double? distanceKm, int? activeCalories, String source = 'health_connect'}) =>
      _client.post('/health/steps/sync', {
        'steps': steps,
        'distanceKm': ?distanceKm,
        'activeCalories': ?activeCalories,
        'source': source,
      });

  Future<Json> todaySteps() async => (await _client.get('/health/steps/today'))['today'];

  // ---- FitPro On-Demand (Trainers) -------------------------------------------
  Future<List<Trainer>> trainers({String? modes, String? category, String? q}) async {
    final r = await _client.get('/trainers', query: {'modes': modes, 'category': category, 'q': q});
    return (r['trainers'] as List).map((t) => Trainer.fromJson(t)).toList();
  }

  Future<({Trainer trainer, List<String> availableSlots})> trainer(String id) async {
    final r = await _client.get('/trainers/$id');
    return (
      trainer: Trainer.fromJson(r['trainer']),
      availableSlots: List<String>.from(r['availableSlots'] as List),
    );
  }

  Future<TrainerBooking> bookTrainer({
    required String trainerId,
    required String mode,
    required String sessionDate,
    required String slotTime,
  }) async {
    final r = await _client.post('/trainers/$trainerId/book', {
      'mode': mode,
      'sessionDate': sessionDate,
      'slotTime': slotTime,
    });
    return TrainerBooking.fromJson(r['booking']);
  }

  Future<List<TrainerBooking>> myTrainerBookings() async {
    final r = await _client.get('/trainers/bookings/me');
    return (r['bookings'] as List).map((b) => TrainerBooking.fromJson(b)).toList();
  }

  // ---- HealthStop Near You --------------------------------------------------
  Future<List<HealthChemist>> healthChemists({String? city}) async {
    final r = await _client.get('/healthstop/chemists', query: {'city': city});
    return (r['chemists'] as List).map((c) => HealthChemist.fromJson(c)).toList();
  }

  Future<List<HealthClinic>> healthClinics({String? city}) async {
    final r = await _client.get('/healthstop/clinics', query: {'city': city});
    return (r['clinics'] as List).map((c) => HealthClinic.fromJson(c)).toList();
  }

  // ---- AI Vision & Mansi (AI coach) -----------------------------------------
  /// Reads a meal photo (`mode: 'meal'`) or a packaged-food nutrition label (`mode: 'label'`).
  Future<FoodItem> extractNutritionFromImage(String base64Image, {String mode = 'meal'}) async {
    final r = await _client.post('/ai/nutrition-from-image', {'imageBase64': base64Image, 'mode': mode});
    return FoodItem.fromJson(r['extracted'] as Json);
  }

  /// Sends the conversation to Mansi. [imageBase64] is attached to the latest user message.
  Future<String> sendChatMessage(List<Map<String, String>> messages, {String? imageBase64}) async {
    final r = await _client.post('/ai/chat', {'messages': messages, 'imageBase64': ?imageBase64});
    return r['reply'] as String;
  }
}
