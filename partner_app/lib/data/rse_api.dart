// Run / Sell / Earn endpoints (docs/partner_brd_contract.md §F) + partner-type Run screens (§H, BRD §10.4).
// Pure helpers (labels, status, money, checklist summary) live at the top so they can be unit-tested.

import 'package:dio/dio.dart' show Dio, Options, ResponseType;
import 'package:fitkey_core/fitkey_core.dart' show AppConfig, apiDate;

import 'brd_api.dart';
import 'memberships_api.dart' show SlotBooking;
import 'models.dart';
import 'partner_api.dart';

int _i(Object? v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
double _d(Object? v) => v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);
String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;
DateTime? _day(Object? v) {
  final s = _s(v);
  if (s == null) return null;
  final d = DateTime.tryParse(s.length >= 10 ? s.substring(0, 10) : s);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

DateTime? _ts(Object? v) => _s(v) == null ? null : DateTime.tryParse(v as String)?.toLocal();
List<Json> _list(Object? v) => [for (final e in (v as List? ?? const [])) Map<String, dynamic>.from(e as Map)];

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/// Where a member came from (contract enum "member source").
enum MemberSource {
  self('self', 'Self', 'Your own member / walk-in'),
  fitkeyPass('fitkey_pass', 'FitKey pass', 'Visits with the FitKey pass'),
  fitkeyDirect('fitkey_direct', 'FitKey direct plan', 'Bought your plan on FitKey'),
  fitpass('fitpass', 'Fitpass', 'Came through Fitpass'),
  other('other', 'Other', 'Any other source');

  const MemberSource(this.api, this.label, this.blurb);
  final String api;
  final String label;
  final String blurb;

  static MemberSource parse(String? v) => MemberSource.values.firstWhere((s) => s.api == v, orElse: () => other);

  /// Rows the partner can add / edit by hand (FitKey rows appear automatically).
  static const manual = [self, fitpass, other];

  bool get isFitkey => this == fitkeyPass || this == fitkeyDirect;
}

/// Short label for an earnings source key; also understands `walk_in` as Self.
String earningSourceLabel(String source) => switch (source) {
  'fitkey_pass' => 'FitKey pass visits',
  'fitkey_direct' => 'FitKey direct plans',
  'self' || 'walk_in' => 'Self / walk-in',
  'fitpass' => 'Fitpass',
  _ => 'Other',
};

enum MemberStatus {
  active('Active'),
  expiring('Expiring'),
  expired('Expired');

  const MemberStatus(this.label);
  final String label;

  static MemberStatus parse(String? v) => MemberStatus.values.firstWhere((s) => s.name == v, orElse: () => active);
}

/// Same rule as the server: expired when the renewal date has passed, expiring within 7 days, else active.
MemberStatus memberStatusFor(DateTime? renewalOn, {DateTime? today}) {
  if (renewalOn == null) return MemberStatus.active;
  final t = today ?? DateTime.now();
  final d0 = DateTime(t.year, t.month, t.day);
  final r = DateTime(renewalOn.year, renewalOn.month, renewalOn.day);
  if (r.isBefore(d0)) return MemberStatus.expired;
  if (r.difference(d0).inDays <= 7) return MemberStatus.expiring;
  return MemberStatus.active;
}

/// Price paid spread over the plan's days (joined → renewal), for the "earning per day" column.
int earningPerDayPaise(int pricePaise, DateTime? joinedOn, DateTime? renewalOn) {
  if (joinedOn == null || renewalOn == null || pricePaise <= 0) return 0;
  final days = DateTime(
    renewalOn.year,
    renewalOn.month,
    renewalOn.day,
  ).difference(DateTime(joinedOn.year, joinedOn.month, joinedOn.day)).inDays;
  return days <= 0 ? pricePaise : (pricePaise / days).round();
}

/// "₹1,234" for small amounts, "₹1.2L" / "₹3.4Cr" for big headline numbers.
String compactRupees(int paise) {
  final r = paise / 100;
  final sign = r < 0 ? '-' : '';
  final a = r.abs();
  String trim(double v) => v.toStringAsFixed(v >= 10 ? 0 : 1).replaceAll(RegExp(r'\.0$'), '');
  if (a >= 1e7) return '$sign₹${trim(a / 1e7)}Cr';
  if (a >= 1e5) return '$sign₹${trim(a / 1e5)}L';
  final whole = a.round().toString();
  // Indian grouping: 1,23,456
  final last3 = whole.length > 3 ? whole.substring(whole.length - 3) : whole;
  var rest = whole.length > 3 ? whole.substring(0, whole.length - 3) : '';
  final parts = <String>[];
  while (rest.length > 2) {
    parts.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) parts.insert(0, rest);
  return '$sign₹${[...parts, last3].join(',')}';
}

/// Parses a rupee amount typed by the partner ("1,499" / "1499.50") into paise.
int? rupeesToPaise(String text) {
  final v = double.tryParse(text.replaceAll(',', '').replaceAll('₹', '').trim());
  return v == null || v < 0 ? null : (v * 100).round();
}

// ---------------------------------------------------------------------------
// Listing checklist (venue GET by id / type listing GET / home)
// ---------------------------------------------------------------------------

class ChecklistItem {
  ChecklistItem.fromJson(Json j) : step = _i(j['step']), label = '${j['label'] ?? 'Step ${j['step']}'}';
  final int step;
  final String label;

  /// "Pricing & FitKey pass" → "Pricing".
  String get shortLabel => label.split(RegExp(r'\s*(&| and )\s*')).first.trim();
}

class SetupChecklist {
  SetupChecklist.fromJson(Json j)
    : percent = _i(j['percent']).clamp(0, 100),
      done = [for (final s in (j['done'] as List? ?? const [])) _i(s)],
      missing = [for (final m in _list(j['missing'])) ChecklistItem.fromJson(m)];

  final int percent;
  final List<int> done;
  final List<ChecklistItem> missing;

  bool get complete => missing.isEmpty || percent >= 100;

  /// "Listing 60% complete: Pricing and Documents left".
  String get summary => checklistSummary(percent, [for (final m in missing) m.shortLabel]);
}

String checklistSummary(int percent, List<String> missing) {
  if (missing.isEmpty) return 'Listing $percent% complete: ready to submit';
  final String left;
  if (missing.length == 1) {
    left = missing.first;
  } else if (missing.length <= 3) {
    left = '${missing.sublist(0, missing.length - 1).join(', ')} and ${missing.last}';
  } else {
    left = '${missing.take(2).join(', ')} and ${missing.length - 2} more';
  }
  return 'Listing $percent% complete: $left left';
}

// ---------------------------------------------------------------------------
// Home
// ---------------------------------------------------------------------------

class SourceAmount {
  SourceAmount.fromJson(Json j)
    : source = '${j['source'] ?? 'other'}',
      count = _i(j['count']),
      grossPaise = _i(j['grossPaise']),
      commissionPaise = _i(j['commissionPaise']),
      gstPaise = _i(j['gstPaise']),
      netPaise = _i(j['netPaise']);

  final String source;
  final int count;
  final int grossPaise;
  final int commissionPaise;
  final int gstPaise;
  final int netPaise;

  String get label => earningSourceLabel(source);
}

class HomeVenue {
  HomeVenue.fromJson(Json j)
    : id = '${j['id']}',
      name = '${j['name'] ?? 'Your venue'}',
      status = VenueStatus.parse(j['status']);
  final String id;
  final String name;
  final VenueStatus status;
}

class PartnerHome {
  PartnerHome.fromJson(Json j)
    : live = j['live'] == true,
      venues = [for (final v in _list(j['venues'])) HomeVenue.fromJson(v)],
      todayPaise = _i((j['earnings'] as Map?)?['todayPaise']),
      weekPaise = _i((j['earnings'] as Map?)?['weekPaise']),
      monthPaise = _i((j['earnings'] as Map?)?['monthPaise']),
      bySource = [for (final s in _list((j['earnings'] as Map?)?['bySource'])) SourceAmount.fromJson(s)],
      checkins = _i((j['today'] as Map?)?['checkins']),
      bookings = _i((j['today'] as Map?)?['bookings']),
      pendingRequests = _i((j['today'] as Map?)?['pendingRequests']),
      renewalsDue = _i((j['today'] as Map?)?['renewalsDue']),
      commission = j['commission'] is Map ? CommissionPlan.fromJson(Map<String, dynamic>.from(j['commission'])) : null,
      checklist = j['checklist'] is Map ? SetupChecklist.fromJson(Map<String, dynamic>.from(j['checklist'])) : null;

  final bool live;
  final List<HomeVenue> venues;
  final int todayPaise;
  final int weekPaise;
  final int monthPaise;
  final List<SourceAmount> bySource;
  final int checkins;
  final int bookings;
  final int pendingRequests;
  final int renewalsDue;
  final CommissionPlan? commission;
  final SetupChecklist? checklist;
}

/// GET /partner/listing/:type (trainer / clinic / chemist / store).
class TypeListingState {
  TypeListingState.fromJson(Json j)
    : listing = j['listing'] is Map ? Map<String, dynamic>.from(j['listing']) : null,
      checklist = j['checklist'] is Map ? SetupChecklist.fromJson(Map<String, dynamic>.from(j['checklist'])) : null;

  final Json? listing;
  final SetupChecklist? checklist;

  String? get id => listing == null ? null : _s('${listing!['id'] ?? ''}');
  VenueStatus get status => VenueStatus.parse(listing?['status'] as String?);
  String get name => '${listing?['name'] ?? listing?['storeName'] ?? listing?['displayName'] ?? 'Your listing'}';
}

// ---------------------------------------------------------------------------
// Members
// ---------------------------------------------------------------------------

class VenueMember {
  VenueMember.fromJson(Json j)
    : key = '${j['key'] ?? j['id'] ?? ''}',
      id = _s(j['id'] == null ? null : '${j['id']}'),
      name = '${j['name'] ?? 'Member'}',
      phone = _s(j['phone']),
      joinedOn = _day(j['joinedOn']),
      planLabel = '${j['planLabel'] ?? ''}',
      renewalOn = _day(j['renewalOn']),
      source = MemberSource.parse(j['source'] as String?),
      pricePaise = _i(j['pricePaise']),
      earningPerDayPaise = _i(j['earningPerDayPaise']),
      status = j['status'] == null ? memberStatusFor(_day(j['renewalOn'])) : MemberStatus.parse(j['status'] as String?),
      manual = j['manual'] == true,
      remindMember = j['remindMember'] == true;

  final String key;
  final String? id;
  final String name;
  final String? phone;
  final DateTime? joinedOn;
  final String planLabel;
  final DateTime? renewalOn;
  final MemberSource source;
  final int pricePaise;
  final int earningPerDayPaise;
  final MemberStatus status;
  final bool manual;
  final bool remindMember;
}

class MemberInput {
  MemberInput({
    required this.name,
    this.phone,
    required this.joinedOn,
    required this.planLabel,
    this.renewalOn,
    required this.source,
    required this.pricePaise,
    this.remindMember = false,
  });

  final String name;
  final String? phone;
  final DateTime joinedOn;
  final String planLabel;
  final DateTime? renewalOn;
  final MemberSource source;
  final int pricePaise;
  final bool remindMember;

  Json toJson() => {
    'name': name,
    'phone': ?phone,
    'joinedOn': apiDate(joinedOn),
    'planLabel': planLabel,
    if (renewalOn != null) 'renewalOn': apiDate(renewalOn!),
    'source': source.api,
    'pricePaise': pricePaise,
    'remindMember': remindMember,
  };
}

// ---------------------------------------------------------------------------
// Slots, requests, closures
// ---------------------------------------------------------------------------

class BoardSlot {
  BoardSlot.fromJson(Json j)
    : start = '${j['start'] ?? ''}',
      end = '${j['end'] ?? ''}',
      capacity = _i(j['capacity']),
      booked = _i(j['booked']),
      passBooked = _i(j['passBooked']),
      passCap = j['passCap'] == null ? null : _i(j['passCap']),
      available = j['available'] == null ? (_i(j['capacity']) - _i(j['booked'])) : _i(j['available']),
      blocked = j['blocked'] == true,
      passBlocked = j['passBlocked'] == true,
      ladiesOnly = j['ladiesOnly'] == true;

  final String start;
  final String end;
  final int capacity;
  final int booked;
  final int passBooked;
  final int? passCap;
  final int available;
  final bool blocked;
  final bool passBlocked;
  final bool ladiesOnly;

  int get ownBooked => (booked - passBooked).clamp(0, booked);
  double get fill => capacity <= 0 ? 0 : (booked / capacity).clamp(0, 1).toDouble();
  String get label =>
      '${start.length >= 5 ? start.substring(0, 5) : start}–${end.length >= 5 ? end.substring(0, 5) : end}';
}

class SlotBoard {
  SlotBoard.fromJson(Json j)
    : date = _day(j['date']),
      slotMinutes = _i(j['slotMinutes']),
      slots = [for (final s in _list(j['slots'])) BoardSlot.fromJson(s)];

  final DateTime? date;
  final int slotMinutes;
  final List<BoardSlot> slots;

  int get total => slots.where((s) => !s.blocked).fold(0, (a, s) => a + s.capacity);
  int get booked => slots.fold(0, (a, s) => a + s.booked);
  int get passBooked => slots.fold(0, (a, s) => a + s.passBooked);
  int get available => slots.where((s) => !s.blocked).fold(0, (a, s) => a + s.available);
}

class VenueClosure {
  VenueClosure.fromJson(Json j)
    : id = '${j['id']}',
      closedOn = _day(j['closedOn']),
      slotStart = _s(j['slotStart']),
      slotEnd = _s(j['slotEnd']),
      note = _s(j['note']);

  final String id;
  final DateTime? closedOn;
  final String? slotStart;
  final String? slotEnd;
  final String? note;

  bool get wholeDay => slotStart == null;
}

// ---------------------------------------------------------------------------
// Earnings & payouts
// ---------------------------------------------------------------------------

class DayAmount {
  DayAmount.fromJson(Json j) : date = _day(j['date']), netPaise = _i(j['netPaise']);
  final DateTime? date;
  final int netPaise;
}

class EarningsBreakdown {
  EarningsBreakdown.fromJson(Json j)
    : grossPaise = _i((j['totals'] as Map?)?['grossPaise']),
      commissionPaise = _i((j['totals'] as Map?)?['commissionPaise']),
      gstPaise = _i((j['totals'] as Map?)?['gstPaise']),
      netPaise = _i((j['totals'] as Map?)?['netPaise']),
      bySource = [for (final s in _list(j['bySource'])) SourceAmount.fromJson(s)],
      byDay = [for (final d in _list(j['byDay'])) DayAmount.fromJson(d)];

  final int grossPaise;
  final int commissionPaise;
  final int gstPaise;
  final int netPaise;
  final List<SourceAmount> bySource;
  final List<DayAmount> byDay;
}

class PassVisit {
  PassVisit.fromJson(Json j)
    : checkinId = '${j['checkinId'] ?? ''}',
      memberName = '${j['memberName'] ?? 'Member'}',
      time = _s(j['time']),
      venueName = _s(j['venueName']),
      grossPaise = _i(j['grossPaise']),
      commissionPct = _d(j['commissionPct']),
      commissionPaise = _i(j['commissionPaise']),
      netPaise = _i(j['netPaise']);

  final String checkinId;
  final String memberName;

  /// "HH:MM" (venue local time).
  final String? time;
  final String? venueName;
  final int grossPaise;
  final double commissionPct;
  final int commissionPaise;
  final int netPaise;
}

class Payout {
  Payout.fromJson(Json j)
    : id = '${j['id']}',
      periodStart = _day(j['periodStart']),
      periodEnd = _day(j['periodEnd']),
      grossPaise = _i(j['grossPaise']),
      commissionPaise = _i(j['commissionPaise']),
      gstPaise = _i(j['gstPaise']),
      netPaise = _i(j['netPaise']),
      status = '${j['status'] ?? 'pending'}',
      utr = _s(j['utr']),
      paidAt = _ts(j['paidAt']);

  final String id;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final int grossPaise;
  final int commissionPaise;
  final int gstPaise;
  final int netPaise;

  /// pending | processing | paid | failed (anything else shown as is)
  final String status;
  final String? utr;
  final DateTime? paidAt;
}

class PayoutsInfo {
  PayoutsInfo.fromJson(Json j)
    : schedule = '${j['schedule'] ?? 'weekly'}',
      nextPayoutOn = _day(j['nextPayoutOn']),
      payouts = [for (final p in _list(j['payouts'])) Payout.fromJson(p)];

  final String schedule;
  final DateTime? nextPayoutOn;
  final List<Payout> payouts;
}

/// Result of scanning a member's QR at the front desk.
class ScanResult {
  ScanResult.fromJson(Json j)
    : memberName =
          _s((j['checkin'] as Map?)?['memberName']) ?? _s((j['member'] as Map?)?['name']) ?? _s(j['memberName']),
      paidVia = _s((j['checkin'] as Map?)?['paidVia']) ?? _s(j['paidVia']),
      message = _s(j['message']);

  final String? memberName;
  final String? paidVia;
  final String? message;
}

// ---------------------------------------------------------------------------
// Trainer / store / clinic / chemist (BRD §10.4, contract "Changes by backend-types")
// ---------------------------------------------------------------------------

/// Earnings endpoint for a partner type (all share the §F earnings shape).
String earningsPathFor(PartnerType type) => switch (type) {
  PartnerType.trainer => '/partner/trainer/earnings',
  PartnerType.clinic => '/partner/clinic/earnings',
  PartnerType.chemist => '/partner/chemist/earnings',
  PartnerType.storeSeller => '/partner/vendor/earnings',
  _ => '/partner/earnings',
};

class TrainerClientRow {
  TrainerClientRow.fromJson(Json j)
    : name = '${j['name'] ?? 'Member'}',
      phone = _s(j['phone']),
      sessions = _i(j['sessions']),
      completed = _i(j['completed']),
      lastSessionOn = _day(j['lastSessionOn']),
      nextSessionOn = _day(j['nextSessionOn']),
      totalPaise = _i(j['totalPaise']);

  final String name;
  final String? phone;
  final int sessions;
  final int completed;
  final DateTime? lastSessionOn;
  final DateTime? nextSessionOn;
  final int totalPaise;
}

class LowStockProduct {
  LowStockProduct.fromJson(Json j)
    : id = '${j['id']}',
      title = '${j['title'] ?? 'Product'}',
      sku = _s(j['sku']),
      category = '${j['category'] ?? ''}',
      stockQuantity = _i(j['stockQuantity']),
      lowStockThreshold = j['lowStockThreshold'] == null ? 5 : _i(j['lowStockThreshold']),
      pricePaise = _i(j['pricePaise']),
      image = (j['images'] as List?)?.whereType<String>().firstOrNull;

  final String id;
  final String title;
  final String? sku;
  final String category;
  final int stockQuantity;
  final int lowStockThreshold;
  final int pricePaise;
  final String? image;
}

class StoreReturn {
  StoreReturn.fromJson(Json j)
    : itemId = '${j['itemId']}',
      orderId = '${j['orderId'] ?? ''}',
      title = '${j['title'] ?? 'Item'}',
      quantity = _i(j['quantity']),
      pricePaise = _i(j['pricePaise']),
      returnStatus = '${j['returnStatus'] ?? 'requested'}',
      reason = _s(j['returnReason']),
      memberName = _s(j['memberName']),
      requestedAt = _ts(j['returnRequestedAt']);

  final String itemId;
  final String orderId;
  final String title;
  final int quantity;
  final int pricePaise;

  /// requested | approved | rejected | received | refunded
  final String returnStatus;
  final String? reason;
  final String? memberName;
  final DateTime? requestedAt;

  String get shortOrderId => orderId.length > 8 ? orderId.substring(0, 8).toUpperCase() : orderId.toUpperCase();

  /// Next actions the seller can take on this return.
  List<String> get actions => switch (returnStatus) {
    'requested' => const ['approved', 'rejected'],
    'approved' => const ['received'],
    'received' => const ['refunded'],
    _ => const [],
  };
}

class ClinicAppointment {
  ClinicAppointment.fromJson(Json j)
    : id = '${j['id']}',
      patientName = '${j['patientName'] ?? 'Patient'}',
      phone = _s(j['patientPhone']),
      doctorName = _s(j['doctorName']),
      date = _day(j['apptDate']),
      time = _s(j['slotTime']),
      token = j['tokenNo'] == null ? null : _i(j['tokenNo']),
      feePaise = _i(j['feePaise']),
      source = '${j['source'] ?? 'fitkey'}',
      status = '${j['status'] ?? 'booked'}',
      reason = _s(j['reason']);

  final String id;
  final String patientName;
  final String? phone;
  final String? doctorName;
  final DateTime? date;
  final String? time;
  final int? token;
  final int feePaise;

  /// fitkey | walk_in
  final String source;

  /// booked | checked_in | in_consultation | completed | cancelled | no_show
  final String status;
  final String? reason;

  bool get open => status == 'booked' || status == 'checked_in' || status == 'in_consultation';
}

/// Next step for the front desk: booked → checked in → with doctor → completed.
String? nextAppointmentStatus(String status) =>
    const {'booked': 'checked_in', 'checked_in': 'in_consultation', 'in_consultation': 'completed'}[status];

class ClinicQueue {
  ClinicQueue.fromJson(Json j)
    : nowServing = j['nowServing'] is Map
          ? ClinicAppointment.fromJson(Map<String, dynamic>.from(j['nowServing']))
          : null,
      queue = [for (final a in _list(j['queue'])) ClinicAppointment.fromJson(a)],
      done = [for (final a in _list(j['done'])) ClinicAppointment.fromJson(a)];

  final ClinicAppointment? nowServing;
  final List<ClinicAppointment> queue;
  final List<ClinicAppointment> done;
}

class ChemistOrder {
  ChemistOrder.fromJson(Json j)
    : id = '${j['id']}',
      customerName = '${j['memberName'] ?? 'Customer'}',
      phone = _s(j['phone']),
      address = _address(j['address']),
      items = [
        for (final i in _list(j['items']))
          (name: '${i['name'] ?? 'Item'}', qty: i['qty'] == null ? 1 : _i(i['qty']), note: _s(i['note'])),
      ],
      delivery = j['fulfilment'] != 'pickup',
      prescriptionUrl = _s(j['prescriptionUrl']),
      mrpPaise = _i(j['mrpPaise']),
      discountPaise = _i(j['discountPaise']),
      amountPaise = _i(j['amountPaise']),
      status = '${j['status'] ?? 'requested'}',
      rejectReason = _s(j['rejectReason']),
      createdAt = _ts(j['createdAt']);

  static String? _address(Object? a) {
    if (a is Map) {
      return [a['addressLine'], a['city'], a['pincode']].where((p) => p != null && '$p'.isNotEmpty).join(', ');
    }
    return _s(a);
  }

  final String id;
  final String customerName;
  final String? phone;
  final String? address;
  final List<({String name, int qty, String? note})> items;
  final bool delivery;
  final String? prescriptionUrl;
  final int mrpPaise;
  final int discountPaise;
  final int amountPaise;

  /// requested | accepted | packed | out_for_delivery | delivered | picked_up | rejected | cancelled
  final String status;
  final String? rejectReason;
  final DateTime? createdAt;

  String get shortId => id.length > 8 ? id.substring(0, 8).toUpperCase() : id.toUpperCase();
  bool get open => const ['requested', 'accepted', 'packed', 'out_for_delivery'].contains(status);

  /// Next forward step: requested → accepted → packed → out for delivery → delivered (pick-up: packed → picked up).
  String? get nextStatus => switch (status) {
    'requested' => 'accepted',
    'accepted' => 'packed',
    'packed' => delivery ? 'out_for_delivery' : 'picked_up',
    'out_for_delivery' => 'delivered',
    _ => null,
  };
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

extension RseApi on PartnerApi {
  Future<PartnerHome> home() async => PartnerHome.fromJson(await client.get('/partner/home'));

  Future<SetupChecklist?> venueChecklist(String id) async {
    final r = await client.get('/partner/venues/$id');
    final c = (r['venue'] as Map?)?['checklist'] ?? r['checklist'];
    return c is Map ? SetupChecklist.fromJson(Map<String, dynamic>.from(c)) : null;
  }

  Future<TypeListingState> typeListing(PartnerType t) async =>
      TypeListingState.fromJson(await client.get('/partner/listing/${t == PartnerType.storeSeller ? 'store' : t.api}'));

  // ---- Members ----
  Future<List<VenueMember>> venueMembers(String venueId, {String? source, String? status, String? q}) async => [
    for (final m in _list(
      (await client.get(
        '/partner/venues/$venueId/members',
        query: {'source': source, 'status': status, 'q': q},
      ))['members'],
    ))
      VenueMember.fromJson(m),
  ];

  Future<void> addVenueMember(String venueId, MemberInput m) =>
      client.post('/partner/venues/$venueId/members', m.toJson());

  Future<void> updateVenueMember(String venueId, String memberId, MemberInput m) =>
      client.put('/partner/venues/$venueId/members/$memberId', m.toJson());

  Future<void> deleteVenueMember(String venueId, String memberId) =>
      client.delete('/partner/venues/$venueId/members/$memberId');

  // ---- Slots & requests ----
  Future<SlotBoard> slotBoard(String venueId, DateTime date) async =>
      SlotBoard.fromJson(await client.get('/partner/venues/$venueId/slot-board', query: {'date': apiDate(date)}));

  /// Undecided booking requests + the venue's auto-accept setting.
  Future<({bool autoAccept, List<SlotBooking> requests})> bookingRequests(String venueId) async {
    final r = await client.get('/partner/venues/$venueId/booking-requests');
    return (
      autoAccept: r['autoAcceptBookings'] != false,
      requests: [for (final b in _list(r['requests'])) SlotBooking.fromJson(b)],
    );
  }

  Future<void> acceptBooking(String bookingId) => client.post('/partner/bookings/$bookingId/accept');

  Future<void> rejectBooking(String bookingId, {String? reason}) =>
      client.post('/partner/bookings/$bookingId/reject', {'reason': ?reason});

  Future<void> setAutoAccept(String venueId, bool on) =>
      client.put('/partner/venues/$venueId/booking-settings', {'autoAcceptBookings': on});

  Future<List<VenueClosure>> closures(String venueId) async => [
    for (final c in _list((await client.get('/partner/venues/$venueId/closures'))['closures']))
      VenueClosure.fromJson(c),
  ];

  /// Returns how many existing bookings fall in the closed time (they are not cancelled automatically).
  Future<int> addClosure(
    String venueId, {
    required DateTime on,
    String? slotStart,
    String? slotEnd,
    String? note,
  }) async => _i(
    (await client.post('/partner/venues/$venueId/closures', {
      'closedOn': apiDate(on),
      'slotStart': ?slotStart,
      'slotEnd': ?slotEnd,
      'note': ?note,
    }))['affectedBookings'],
  );

  Future<void> deleteClosure(String venueId, String closureId) =>
      client.delete('/partner/venues/$venueId/closures/$closureId');

  /// Front desk scans the member's FitKey QR.
  Future<ScanResult> scanCheckin(String venueId, String code) async =>
      ScanResult.fromJson(await client.post('/partner/venues/$venueId/checkin/scan', {'code': code}));

  // ---- Earnings & payouts ----
  Future<EarningsBreakdown> earningsBreakdown({
    required DateTime from,
    required DateTime to,
    String? venueId,
    PartnerType type = PartnerType.fitnessCentre,
  }) async => EarningsBreakdown.fromJson(
    await client.get(
      earningsPathFor(type),
      query: {'from': apiDate(from), 'to': apiDate(to), if (type.isVenue) 'venueId': venueId},
    ),
  );

  Future<List<PassVisit>> passVisits(DateTime date, {String? venueId}) async => [
    for (final v in _list(
      (await client.get('/partner/earnings/visits', query: {'date': apiDate(date), 'venueId': venueId}))['visits'],
    ))
      PassVisit.fromJson(v),
  ];

  Future<PayoutsInfo> payouts() async => PayoutsInfo.fromJson(await client.get('/partner/payouts'));

  /// Downloads an authenticated file (CSV statement / HTML invoice) as bytes — the browser can't send our token.
  Future<List<int>> downloadBytes(String path) async {
    final res = await Dio().get<List<int>>(
      '${AppConfig.apiUrl}$path',
      options: Options(
        responseType: ResponseType.bytes,
        headers: {if (client.token != null) 'Authorization': 'Bearer ${client.token}'},
      ),
    );
    return res.data ?? const [];
  }

  // ---- Trainer / store ----
  Future<List<TrainerClientRow>> trainerClients() async => [
    for (final c in _list((await client.get('/partner/trainer/clients'))['clients'])) TrainerClientRow.fromJson(c),
  ];

  Future<List<LowStockProduct>> lowStock() async => [
    for (final p in _list((await client.get('/partner/vendor/low-stock'))['products'])) LowStockProduct.fromJson(p),
  ];

  Future<List<StoreReturn>> storeReturns() async => [
    for (final r in _list((await client.get('/partner/vendor/returns'))['returns'])) StoreReturn.fromJson(r),
  ];

  Future<void> setReturnStatus(String itemId, String status) =>
      client.post('/partner/vendor/returns/$itemId', {'status': status});

  // ---- Clinic / chemist ----
  Future<List<ClinicAppointment>> clinicAppointments({DateTime? from}) async => [
    for (final a in _list(
      (await client.get(
        '/partner/clinic/appointments',
        query: {'from': from == null ? null : apiDate(from)},
      ))['appointments'],
    ))
      ClinicAppointment.fromJson(a),
  ];

  Future<ClinicQueue> clinicQueue({DateTime? date}) async => ClinicQueue.fromJson(
    await client.get('/partner/clinic/queue', query: {'date': date == null ? null : apiDate(date)}),
  );

  Future<void> setAppointmentStatus(String id, String status) =>
      client.post('/partner/clinic/appointments/$id/status', {'status': status});

  Future<List<ChemistOrder>> chemistOrders({bool openOnly = false}) async => [
    for (final o in _list(
      (await client.get('/partner/chemist/orders', query: {'open': openOnly ? 'true' : null}))['orders'],
    ))
      ChemistOrder.fromJson(o),
  ];

  /// [mrpPaise] is required when accepting (the store discount is applied server-side).
  Future<void> setChemistOrderStatus(String id, String status, {int? mrpPaise, String? rejectReason}) => client.post(
    '/partner/chemist/orders/$id',
    {'status': status, 'mrpPaise': ?mrpPaise, 'rejectReason': ?rejectReason},
  );
}

/// Today / this week (from Monday) / this month totals from a per-day series — used for partner types whose
/// earnings endpoint has no home summary.
({int today, int week, int month}) periodTotals(List<DayAmount> days, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final weekStart = today.subtract(Duration(days: today.weekday - 1));
  final monthStart = DateTime(today.year, today.month);
  var t = 0, w = 0, m = 0;
  for (final d in days) {
    final date = d.date;
    if (date == null || date.isAfter(today)) continue;
    if (date == today) t += d.netPaise;
    if (!date.isBefore(weekStart)) w += d.netPaise;
    if (!date.isBefore(monthStart)) m += d.netPaise;
  }
  return (today: t, week: w, month: m);
}
