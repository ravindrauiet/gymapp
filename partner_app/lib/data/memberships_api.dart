import 'models.dart' show Json;
import 'partner_api.dart';

// Centre memberships (BRD §2.2) and slot bookings / visits / earnings (BRD §3.2) — partner side.
// Endpoints: /memberships/partner/*, /bookings/partner/*.

int _i(dynamic v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
int? _iOrNull(dynamic v) => v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));
double _d(dynamic v) => v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);
String? _s(dynamic v) => v is String && v.isNotEmpty ? v : null;
List<String> _strings(dynamic v) => (v as List? ?? const []).map((e) => e.toString()).toList();
DateTime? _ts(dynamic v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
Map<String, int> _counts(dynamic v) =>
    v is Map ? {for (final e in v.entries) '${e.key}': _i(e.value)} : <String, int>{};

/// A date-only value ("2026-11-05") as a local midnight DateTime.
DateTime? _day(dynamic v) {
  if (v is! String || v.length < 10) return null;
  final p = v.substring(0, 10).split('-').map(int.tryParse).toList();
  if (p.length != 3 || p.contains(null)) return null;
  return DateTime(p[0]!, p[1]!, p[2]!);
}

/// Plan durations the backend accepts, with their labels and length.
const planDurations = <String, ({String label, int days})>{
  'day': (label: 'Day pass', days: 1),
  'monthly': (label: 'Monthly', days: 30),
  'quarterly': (label: 'Quarterly', days: 90),
  'annual': (label: 'Annual', days: 365),
};

String durationLabel(String d) => planDurations[d]?.label ?? d;

/// The member-facing price after an offer, rounded like the backend does.
int priceAfterOffer(int pricePaise, int offerPct) => (pricePaise * (100 - offerPct) / 100).round();

// ---------------------------------------------------------------------------
// Membership plans
// ---------------------------------------------------------------------------

class CentrePlan {
  CentrePlan.fromJson(Json j)
      : id = '${j['id']}',
        name = '${j['name'] ?? 'Plan'}',
        description = _s(j['description']),
        duration = '${j['duration'] ?? 'monthly'}',
        durationDays = _i(j['durationDays']),
        pricePaise = _i(j['pricePaise']),
        offerPct = _i(j['offerPct']),
        effectivePricePaise = _i(j['effectivePricePaise'] ?? j['pricePaise']),
        inclusions = _strings(j['inclusions']),
        maxVisitsPerDay = _iOrNull(j['maxVisitsPerDay']),
        maxVisitsPerWeek = _iOrNull(j['maxVisitsPerWeek']),
        isActive = j['isActive'] != false,
        approvalStatus = '${j['approvalStatus'] ?? 'pending'}',
        reviewNote = _s(j['reviewNote']),
        sold = _i(j['sold']),
        activeMembers = _i(j['activeMembers']),
        updatedAt = _ts(j['updatedAt']);

  final String id;
  final String name;
  final String? description;
  final String duration;
  final int durationDays;
  final int pricePaise;
  final int offerPct;
  final int effectivePricePaise;
  final List<String> inclusions;
  final int? maxVisitsPerDay;
  final int? maxVisitsPerWeek;
  final bool isActive;

  /// pending | approved | rejected
  final String approvalStatus;
  final String? reviewNote;
  final int sold;
  final int activeMembers;
  final DateTime? updatedAt;

  bool get isLive => approvalStatus == 'approved' && isActive;

  Json toBody() => {
        'name': name,
        'description': description,
        'duration': duration,
        'pricePaise': pricePaise,
        'inclusions': inclusions,
        'maxVisitsPerDay': maxVisitsPerDay,
        'maxVisitsPerWeek': maxVisitsPerWeek,
        'offerPct': offerPct,
        'isActive': isActive,
      };
}

typedef PlanList = ({List<CentrePlan> plans, double commissionPct});

// ---------------------------------------------------------------------------
// Members
// ---------------------------------------------------------------------------

/// A member who bought this centre's own membership.
class DirectMember {
  DirectMember.fromJson(Json j)
      : id = '${j['id']}',
        memberName = '${j['memberName'] ?? 'Member'}',
        phoneLast4 = _s(j['phoneLast4']),
        planName = '${j['planName'] ?? 'Membership'}',
        duration = '${j['duration'] ?? ''}',
        startsOn = _day(j['startsOn']),
        endsOn = _day(j['endsOn']),
        state = '${j['state'] ?? 'active'}',
        daysLeft = _i(j['daysLeft']),
        amountPaise = _i(j['amountPaise']),
        commissionPaise = _i(j['commissionPaise']),
        maxVisitsPerDay = _iOrNull(j['maxVisitsPerDay']),
        maxVisitsPerWeek = _iOrNull(j['maxVisitsPerWeek']),
        visits = _i(j['visits']),
        lastVisitAt = _ts(j['lastVisitAt']),
        boughtAt = _ts(j['createdAt']);

  final String id;
  final String memberName;
  final String? phoneLast4;
  final String planName;
  final String duration;
  final DateTime? startsOn;
  final DateTime? endsOn;

  /// active | upcoming | expired | cancelled
  final String state;
  final int daysLeft;
  final int amountPaise;
  final int commissionPaise;
  final int? maxVisitsPerDay;
  final int? maxVisitsPerWeek;
  final int visits;
  final DateTime? lastVisitAt;
  final DateTime? boughtAt;
}

/// A member who visited on a FitKey pass (coins / session plan / legacy pass) — FitKey pays the centre per visit.
class FitkeyVisitor {
  FitkeyVisitor.fromJson(Json j)
      : memberName = '${j['memberName'] ?? 'Member'}',
        phoneLast4 = _s(j['phoneLast4']),
        visits = _i(j['visits']),
        coinsVisits = _i(j['coinsVisits']),
        sessionVisits = _i(j['sessionVisits']),
        legacyVisits = _i(j['legacyVisits']),
        payoutPaise = _i(j['payoutPaise']),
        lastVisitAt = _ts(j['lastVisitAt']);

  final String memberName;
  final String? phoneLast4;
  final int visits;
  final int coinsVisits;
  final int sessionVisits;
  final int legacyVisits;
  final int payoutPaise;
  final DateTime? lastVisitAt;
}

// ---------------------------------------------------------------------------
// Bookings, slots & visits
// ---------------------------------------------------------------------------

class SlotBooking {
  SlotBooking.fromJson(Json j)
      : id = '${j['id']}',
        slotDate = _day(j['slotDate']),
        slotStart = '${j['slotStart'] ?? ''}',
        slotEnd = '${j['slotEnd'] ?? ''}',
        status = '${j['status'] ?? 'booked'}',
        paidVia = _s(j['paidVia']),
        costLabel = _s(j['costLabel']),
        costAmount = _i(j['costAmount']),
        refunded = j['refunded'] == true,
        memberName = '${j['memberName'] ?? 'Member'}',
        phoneLast4 = _s(j['phoneLast4']),
        membershipName = _s(j['membershipName']),
        attendedAt = _ts(j['attendedAt']),
        cancelledAt = _ts(j['cancelledAt']);

  final String id;
  final DateTime? slotDate;
  final String slotStart;
  final String slotEnd;

  /// booked | attended | cancelled
  final String status;

  /// coins | session | membership | legacy
  final String? paidVia;
  final String? costLabel;
  final int costAmount;
  final bool refunded;
  final String memberName;
  final String? phoneLast4;
  final String? membershipName;
  final DateTime? attendedAt;
  final DateTime? cancelledAt;
}

class BookingsReport {
  BookingsReport.fromJson(Json j)
      : from = '${j['from'] ?? ''}',
        to = '${j['to'] ?? ''}',
        count = _i(j['count']),
        counts = _counts(j['counts']),
        byPaidVia = _counts(j['byPaidVia']),
        bookings = (j['bookings'] as List? ?? const []).map((b) => SlotBooking.fromJson(Map<String, dynamic>.from(b))).toList();

  final String from;
  final String to;
  final int count;
  final Map<String, int> counts;
  final Map<String, int> byPaidVia;
  final List<SlotBooking> bookings;
}

class SlotLoad {
  SlotLoad.fromJson(Json j)
      : start = '${j['start'] ?? ''}',
        end = '${j['end'] ?? ''}',
        capacity = _i(j['capacity']),
        booked = _i(j['booked']);

  final String start;
  final String end;
  final int capacity;
  final int booked;

  double get fill => capacity <= 0 ? 0 : (booked / capacity).clamp(0, 1).toDouble();
}

class SlotDay {
  SlotDay.fromJson(Json j)
      : date = '${j['date'] ?? ''}',
        capacity = _i(j['capacity']),
        open = j['open'] == true,
        slots = (j['slots'] as List? ?? const []).map((s) => SlotLoad.fromJson(Map<String, dynamic>.from(s))).toList();

  final String date;
  final int capacity;
  final bool open;
  final List<SlotLoad> slots;
}

class VenueVisit {
  VenueVisit.fromJson(Json j)
      : id = '${j['id']}',
        checkinDate = _day(j['checkinDate']),
        checkedInAt = _ts(j['checkedInAt']),
        method = _s(j['method']),
        paidVia = _s(j['paidVia']) ?? 'legacy',
        costLabel = _s(j['costLabel']),
        booked = j['booked'] == true,
        memberName = '${j['memberName'] ?? 'Member'}',
        phoneLast4 = _s(j['phoneLast4']),
        membershipName = _s(j['membershipName']),
        payoutPaise = _iOrNull(j['payoutPaise']);

  final String id;
  final DateTime? checkinDate;
  final DateTime? checkedInAt;
  final String? method;
  final String paidVia;
  final String? costLabel;
  final bool booked;
  final String memberName;
  final String? phoneLast4;
  final String? membershipName;
  final int? payoutPaise;
}

class VisitsReport {
  VisitsReport.fromJson(Json j)
      : count = _i(j['count']),
        byPaidVia = _counts(j['byPaidVia']),
        payoutPaise = _i(j['payoutPaise']),
        visits = (j['visits'] as List? ?? const []).map((v) => VenueVisit.fromJson(Map<String, dynamic>.from(v))).toList();

  final int count;
  final Map<String, int> byPaidVia;
  final int payoutPaise;
  final List<VenueVisit> visits;
}

// ---------------------------------------------------------------------------
// Earnings & statement
// ---------------------------------------------------------------------------

class EarningsMonth {
  EarningsMonth.fromJson(Json j)
      : month = '${j['month'] ?? ''}',
        membershipsSold = _i(j['membershipsSold']),
        membershipGrossPaise = _i(j['membershipGrossPaise']),
        commissionPaise = _i(j['commissionPaise']),
        membershipNetPaise = _i(j['membershipNetPaise']),
        fitkeyVisits = _i(j['fitkeyVisits']),
        visitPayoutPaise = _i(j['visitPayoutPaise']),
        coinsVisits = _i(j['coinsVisits']),
        sessionVisits = _i(j['sessionVisits']),
        legacyVisits = _i(j['legacyVisits']),
        membershipVisits = _i(j['membershipVisits']),
        totalPayablePaise = _i(j['totalPayablePaise']);

  /// "YYYY-MM"
  final String month;
  final int membershipsSold;
  final int membershipGrossPaise;
  final int commissionPaise;
  final int membershipNetPaise;
  final int fitkeyVisits;
  final int visitPayoutPaise;
  final int coinsVisits;
  final int sessionVisits;
  final int legacyVisits;
  final int membershipVisits;
  final int totalPayablePaise;

  DateTime get monthStart {
    final p = month.split('-');
    return DateTime(int.tryParse(p.first) ?? 2000, p.length > 1 ? int.tryParse(p[1]) ?? 1 : 1);
  }
}

typedef EarningsVenue = ({String id, String name, int payoutPerVisitPaise, double commissionPct});

class EarningsReport extends EarningsMonth {
  EarningsReport.fromJson(super.j)
      : venues = (j['venues'] as List? ?? const [])
            .map((v) => (
                  id: '${(v as Map)['id']}',
                  name: '${v['name'] ?? 'Venue'}',
                  payoutPerVisitPaise: _i(v['payoutPerVisitPaise']),
                  commissionPct: _d(v['commissionPct']),
                ))
            .toList(),
        paymentsMode = '${j['paymentsMode'] ?? 'mock'}',
        super.fromJson();

  final List<EarningsVenue> venues;

  /// "mock" while no payment gateway is connected.
  final String paymentsMode;

  bool get isMock => paymentsMode == 'mock';
}

class PayoutStatement {
  PayoutStatement.fromJson(Json j)
      : months = (j['months'] as List? ?? const []).map((m) => EarningsMonth.fromJson(Map<String, dynamic>.from(m))).toList(),
        totals = _counts(j['totals']);

  /// Newest month first.
  final List<EarningsMonth> months;
  final Map<String, int> totals;
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

extension MembershipsApi on PartnerApi {
  // ---- Plans ----------------------------------------------------------------
  Future<PlanList> centrePlans(String venueId) async {
    final r = await client.get('/memberships/partner/venues/$venueId/plans');
    return (
      plans: (r['plans'] as List? ?? const []).map((p) => CentrePlan.fromJson(Map<String, dynamic>.from(p))).toList(),
      commissionPct: _d(r['commissionPct']),
    );
  }

  Future<CentrePlan> createCentrePlan(String venueId, Json body) async =>
      CentrePlan.fromJson((await client.post('/memberships/partner/venues/$venueId/plans', body))['plan']);

  Future<CentrePlan> updateCentrePlan(String planId, Json body) async =>
      CentrePlan.fromJson((await client.put('/memberships/partner/plans/$planId', body))['plan']);

  Future<CentrePlan> setCentrePlanActive(String planId, bool isActive) async =>
      CentrePlan.fromJson((await client.patch('/memberships/partner/plans/$planId/active', {'isActive': isActive}))['plan']);

  Future<CentrePlan> setCentrePlanOffer(String planId, int offerPct) async =>
      CentrePlan.fromJson((await client.patch('/memberships/partner/plans/$planId/offer', {'offerPct': offerPct}))['plan']);

  Future<void> archiveCentrePlan(String planId) => client.delete('/memberships/partner/plans/$planId');

  // ---- Members --------------------------------------------------------------
  /// [status]: active | upcoming | expired | all
  Future<List<DirectMember>> directMembers(String venueId, {String status = 'active'}) async {
    final r = await client.get('/memberships/partner/venues/$venueId/members', query: {'status': status});
    return (r['members'] as List? ?? const []).map((m) => DirectMember.fromJson(Map<String, dynamic>.from(m))).toList();
  }

  Future<List<FitkeyVisitor>> fitkeyVisitors(String venueId, {String? from, String? to}) async {
    final r = await client.get('/memberships/partner/venues/$venueId/fitkey-visitors', query: {'from': from, 'to': to});
    return (r['visitors'] as List? ?? const []).map((v) => FitkeyVisitor.fromJson(Map<String, dynamic>.from(v))).toList();
  }

  // ---- Bookings, slots, visits ---------------------------------------------
  Future<BookingsReport> venueBookings(String venueId, {String? date, String? from, String? to, String? status, String? paidVia}) async =>
      BookingsReport.fromJson(await client.get('/bookings/partner/venues/$venueId/bookings',
          query: {'date': date, 'from': from, 'to': to, 'status': status, 'paidVia': paidVia}));

  Future<SlotDay> venueSlots(String venueId, {String? date}) async =>
      SlotDay.fromJson(await client.get('/bookings/partner/venues/$venueId/slots', query: {'date': date}));

  Future<VisitsReport> venueVisits(String venueId, {String? date, String? from, String? to}) async =>
      VisitsReport.fromJson(
          await client.get('/bookings/partner/venues/$venueId/visits', query: {'date': date, 'from': from, 'to': to}));

  // ---- Earnings -------------------------------------------------------------
  /// [month] is "YYYY-MM"; all own venues when [venueId] is null.
  Future<EarningsReport> partnerEarnings({String? venueId, String? month}) async =>
      EarningsReport.fromJson(await client.get('/memberships/partner/earnings', query: {'venueId': venueId, 'month': month}));

  Future<PayoutStatement> payoutStatement({String? venueId, int months = 12}) async => PayoutStatement.fromJson(
      await client.get('/memberships/partner/statement', query: {'venueId': venueId, 'months': '$months'}));
}
