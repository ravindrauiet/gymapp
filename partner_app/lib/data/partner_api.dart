import 'package:fitkey_core/fitkey_core.dart';

import 'models.dart';

/// Partner-facing endpoints of the shared FITKEY API (role = partner).
class PartnerApi {
  PartnerApi(this._client);

  final ApiClient _client;

  // ---- Auth & profile -------------------------------------------------------
  Future<String?> requestOtp(String phone) async =>
      (await _client.post('/auth/otp/request', {'phone': phone, 'role': 'partner'}))['devOtp'] as String?;

  Future<({String token, PartnerUser user})> verifyOtp(String phone, String otp) async {
    final r = await _client.post('/auth/otp/verify', {'phone': phone, 'otp': otp, 'role': 'partner'});
    return (token: r['token'] as String, user: PartnerUser.fromJson(r['user']));
  }

  Future<PartnerUser> me() async => PartnerUser.fromJson((await _client.get('/me'))['user']);

  Future<PartnerUser> updateProfile(Json fields) async =>
      PartnerUser.fromJson((await _client.patch('/me', fields))['user']);

  // ---- Venues ---------------------------------------------------------------
  Future<List<VenueListItem>> venues() async =>
      ((await _client.get('/partner/venues'))['venues'] as List).map((v) => VenueListItem.fromJson(v)).toList();

  Future<PartnerVenue> venue(String id) async => PartnerVenue.fromJson((await _client.get('/partner/venues/$id'))['venue']);

  Future<PartnerVenue> createVenue(PartnerVenue v) async =>
      PartnerVenue.fromJson((await _client.post('/partner/venues', v.toJson()))['venue']);

  Future<PartnerVenue> updateVenue(PartnerVenue v) async =>
      PartnerVenue.fromJson((await _client.put('/partner/venues/${v.id}', v.toJson()))['venue']);

  Future<PartnerVenue> submitVenue(String id) async =>
      PartnerVenue.fromJson((await _client.post('/partner/venues/$id/submit'))['venue']);

  Future<void> deleteVenue(String id) => _client.delete('/partner/venues/$id');

  /// Uploads a photo and returns its URL (server-relative path).
  Future<String> uploadPhoto(String filePath, {void Function(double)? onProgress}) async =>
      (await _client.uploadImage('/uploads', filePath, onProgress: onProgress))['url'] as String;

  // ---- Check-in & attendance -----------------------------------------------
  Future<CheckinCode> checkinCode(String venueId) async =>
      CheckinCode.fromJson(await _client.get('/partner/venues/$venueId/checkin-code'));

  Future<List<AttendanceEntry>> attendance(String venueId, {String? date}) async =>
      ((await _client.get('/partner/venues/$venueId/attendance', query: {'date': date}))['checkins'] as List)
          .map((c) => AttendanceEntry.fromJson(c))
          .toList();

  Future<AttendanceSummary> attendanceSummary(String venueId, {String? month}) async =>
      AttendanceSummary.fromJson(await _client.get('/partner/venues/$venueId/attendance/summary', query: {'month': month}));

  // ---- Vendor Portal (Marketplace) ------------------------------------------
  Future<VendorProfile?> vendorProfile() async {
    final r = await _client.get('/partner/vendor/profile');
    final v = r['vendor'];
    return v == null ? null : VendorProfile.fromJson(v);
  }

  Future<VendorProfile> saveVendorProfile(Json fields) async {
    final r = await _client.post('/partner/vendor/profile', fields);
    return VendorProfile.fromJson(r['vendor']);
  }

  Future<List<VendorProduct>> vendorProducts() async {
    final r = await _client.get('/partner/vendor/products');
    return (r['products'] as List).map((p) => VendorProduct.fromJson(p)).toList();
  }

  Future<VendorProduct> createVendorProduct(Json fields) async {
    final r = await _client.post('/partner/vendor/products', fields);
    return VendorProduct.fromJson(r['product']);
  }

  Future<VendorProduct> updateVendorProduct(String id, Json fields) async {
    final r = await _client.put('/partner/vendor/products/$id', fields);
    return VendorProduct.fromJson(r['product']);
  }

  Future<List<VendorOrder>> vendorOrders() async {
    final r = await _client.get('/partner/vendor/orders');
    return (r['orders'] as List).map((o) => VendorOrder.fromJson(o)).toList();
  }

  Future<void> updateOrderStatus(String orderId, String status, {String? trackingNumber}) =>
      _client.patch('/partner/vendor/orders/$orderId/status', {
        'status': status,
        'trackingNumber': ?trackingNumber,
      });

  Future<CommissionReport> commissionReport() async {
    final r = await _client.get('/partner/vendor/commissions');
    return CommissionReport.fromJson(r);
  }

  // ---- Trainer Module (FitPro On-Demand) -------------------------------------
  Future<PartnerTrainerProfile?> trainerProfile() async {
    final r = await _client.get('/partner/trainer/profile');
    final t = r['trainer'];
    return t == null ? null : PartnerTrainerProfile.fromJson(t);
  }

  Future<PartnerTrainerProfile> saveTrainerProfile(Json fields) async {
    final r = await _client.post('/partner/trainer/profile', fields);
    return PartnerTrainerProfile.fromJson(r['trainer']);
  }

  Future<List<TrainerBookingItem>> trainerBookings() async {
    final r = await _client.get('/partner/trainer/bookings');
    return (r['bookings'] as List).map((b) => TrainerBookingItem.fromJson(b)).toList();
  }
}
