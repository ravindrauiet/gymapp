import 'fitkey_api.dart';
import 'models.dart';

// Slot booking + direct centre memberships (BRD §2). Backend: routes/bookings.js, routes/memberships.js.

int _i(Object? v) => v == null ? 0 : (v as num).toInt();
int? _iOrNull(Object? v) => v == null ? null : (v as num).toInt();
DateTime _d(Object? v) => DateTime.parse(v as String).toLocal();
DateTime? _dOrNull(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
List<String> _s(Object? v) => v == null ? const [] : List<String>.from(v as List);

/// "YYYY-MM-DD" → local calendar date (no time-zone shift).
DateTime parseDay(String ymd) {
  final p = ymd.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

/// How one visit would be (or was) paid: membership / session / coins / legacy pass.
class VisitCost {
  VisitCost.fromJson(Json j)
      : method = j['method'],
        amount = _i(j['amount']),
        label = j['label'] ?? '',
        sufficient = j['sufficient'] == true,
        balance = _iOrNull(j['balance']),
        available = j['available'] != false,
        membershipName = j['membershipName'],
        membershipLimit = j['membershipLimit'];

  /// membership | session | coins | legacy_pass | null (nothing can pay).
  final String? method;
  final int amount;

  /// e.g. "120 coins", "1 session", "Included in your pass", "Included in your membership".
  final String label;
  final bool sufficient;
  final int? balance;

  /// False while coin / session payments are not live on the server.
  final bool available;
  final String? membershipName;

  /// Set when the member has a membership here but its slot limit is used up.
  final String? membershipLimit;

  bool get canPay => method != null && sufficient;
  bool get isFree => method == 'membership' || method == 'legacy_pass';
}

class SlotDay {
  SlotDay.fromJson(Json j)
      : date = j['date'],
        weekday = j['weekday'],
        open = j['open'] == true;
  final String date;
  final String weekday;
  final bool open;
}

class Slot {
  Slot.fromJson(Json j)
      : start = j['start'],
        end = j['end'],
        capacity = _i(j['capacity']),
        booked = _i(j['booked']),
        left = _i(j['left']),
        past = j['past'] == true,
        available = j['available'] == true;
  final String start;
  final String end;
  final int capacity;
  final int booked;
  final int left;
  final bool past;
  final bool available;
}

class SlotsInfo {
  SlotsInfo.fromJson(Json j)
      : venueName = j['venue']['name'],
        venueArea = j['venue']['area'],
        coverPhoto = j['venue']['coverPhoto'],
        date = j['date'],
        days = (j['days'] as List).map((d) => SlotDay.fromJson(d)).toList(),
        slots = (j['slots'] as List).map((s) => Slot.fromJson(s)).toList(),
        cost = VisitCost.fromJson(j['cost']),
        myBooking = j['myBooking'] == null ? null : Json.from(j['myBooking']),
        freeCancelHours = _i(j['freeCancelHours']);
  final String venueName;
  final String? venueArea;
  final String? coverPhoto;
  final String date;
  final List<SlotDay> days;
  final List<Slot> slots;
  final VisitCost cost;

  /// The member's live booking at this centre that day ({id, slotStart, slotEnd, …}) if any.
  final Json? myBooking;
  final int freeCancelHours;
}

class SlotBooking {
  SlotBooking.fromJson(Json j)
      : id = j['id'],
        venueId = j['venueId'],
        venueName = j['venueName'] ?? '',
        venueArea = j['venueArea'],
        venueCategories = _s(j['venueCategories']),
        venueCoverPhoto = j['venueCoverPhoto'],
        slotDate = j['slotDate'],
        slotStart = j['slotStart'],
        slotEnd = j['slotEnd'],
        status = j['status'],
        paidVia = j['paidVia'],
        costLabel = j['costLabel'],
        refunded = j['refunded'] == true,
        startsAt = _dOrNull(j['startsAt']),
        canCancel = j['canCancel'] == true,
        freeCancel = j['freeCancel'] == true;
  final String id;
  final String venueId;
  final String venueName;
  final String? venueArea;
  final List<String> venueCategories;
  final String? venueCoverPhoto;
  final String slotDate;
  final String slotStart;
  final String slotEnd;

  /// booked | attended | cancelled
  final String status;

  /// coins | session | membership | legacy
  final String? paidVia;
  final String? costLabel;
  final bool refunded;
  final DateTime? startsAt;
  final bool canCancel;
  final bool freeCancel;
}

class CentrePlan {
  CentrePlan.fromJson(Json j)
      : id = j['id'],
        venueId = j['venueId'],
        name = j['name'],
        description = j['description'],
        duration = j['duration'],
        durationDays = _i(j['durationDays']),
        pricePaise = _i(j['pricePaise']),
        effectivePricePaise = _i(j['effectivePricePaise']),
        offerPct = _i(j['offerPct']),
        inclusions = _s(j['inclusions']),
        maxVisitsPerDay = _iOrNull(j['maxVisitsPerDay']),
        maxVisitsPerWeek = _iOrNull(j['maxVisitsPerWeek']);
  final String id;
  final String venueId;
  final String name;
  final String? description;

  /// day | monthly | quarterly | annual
  final String duration;
  final int durationDays;
  final int pricePaise;
  final int effectivePricePaise;
  final int offerPct;
  final List<String> inclusions;
  final int? maxVisitsPerDay;
  final int? maxVisitsPerWeek;

  String get durationLabel => durationLabelOf(duration);

  String? get limitsLabel {
    final parts = [
      if (maxVisitsPerDay != null) '$maxVisitsPerDay visit${maxVisitsPerDay == 1 ? '' : 's'}/day',
      if (maxVisitsPerWeek != null) '$maxVisitsPerWeek visit${maxVisitsPerWeek == 1 ? '' : 's'}/week',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

String durationLabelOf(String d) =>
    const {'day': 'Day pass', 'monthly': 'Monthly', 'quarterly': 'Quarterly', 'annual': 'Annual'}[d] ?? d;

class DirectMembership {
  DirectMembership.fromJson(Json j)
      : id = j['id'],
        venueId = j['venueId'],
        venueName = j['venueName'] ?? '',
        venueArea = j['venueArea'],
        venueCategories = _s(j['venueCategories']),
        venueCoverPhoto = j['venueCoverPhoto'],
        planId = j['planId'],
        planName = j['planName'],
        duration = j['duration'],
        startsOn = j['startsOn'],
        endsOn = j['endsOn'],
        amountPaise = _i(j['amountPaise']),
        maxVisitsPerDay = _iOrNull(j['maxVisitsPerDay']),
        maxVisitsPerWeek = _iOrNull(j['maxVisitsPerWeek']),
        inclusions = _s(j['inclusions']),
        state = j['state'],
        daysLeft = _i(j['daysLeft']),
        canRenew = j['canRenew'] == true;
  final String id;
  final String venueId;
  final String venueName;
  final String? venueArea;
  final List<String> venueCategories;
  final String? venueCoverPhoto;
  final String? planId;
  final String planName;
  final String duration;
  final String startsOn;
  final String endsOn;
  final int amountPaise;
  final int? maxVisitsPerDay;
  final int? maxVisitsPerWeek;
  final List<String> inclusions;

  /// active | upcoming | expired | cancelled
  final String state;
  final int daysLeft;
  final bool canRenew;
}

class LegacyPass {
  LegacyPass.fromJson(Json j)
      : id = j['id'],
        planName = j['planName'],
        categories = _s(j['categories']),
        startsAt = _d(j['startsAt']),
        endsAt = _d(j['endsAt']),
        state = j['state'] ?? 'active';
  final String id;
  final String planName;
  final List<String> categories;
  final DateTime startsAt;
  final DateTime endsAt;
  final String state;
}

class SessionPass {
  SessionPass.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        sessionsLeft = _i(j['sessionsLeft']),
        sessionsTotal = _i(j['sessionsTotal']),
        expiresAt = _d(j['expiresAt']);
  final String id;
  final String name;
  final int sessionsLeft;
  final int sessionsTotal;
  final DateTime expiresAt;
}

class FitkeyPassSummary {
  FitkeyPassSummary.fromJson(Json j)
      : legacy = ((j['legacy'] as List?) ?? const []).map((p) => LegacyPass.fromJson(p)).toList(),
        sessionPlans = ((j['sessionPlans'] as List?) ?? const []).map((p) => SessionPass.fromJson(p)).toList(),
        coinBalance = j['coins'] == null ? null : _i(j['coins']['balance']),
        coinsNextExpiry = j['coins'] == null ? null : _dOrNull(j['coins']['nextExpiry']),
        hasPass = j['hasPass'] == true;
  final List<LegacyPass> legacy;
  final List<SessionPass> sessionPlans;
  final int? coinBalance;
  final DateTime? coinsNextExpiry;
  final bool hasPass;
}

/// What the member holds for one centre (venue page).
class VenueAccess {
  VenueAccess.fromJson(Json j)
      : hasFitkeyPass = j['hasFitkeyPass'] == true,
        fitkey = VisitCost.fromJson(j['fitkey']),
        legacyPlanName = j['legacy']?['planName'],
        memberships = ((j['memberships'] as List?) ?? const []).map((m) => Json.from(m)).toList(),
        hasMembership = j['hasMembership'] == true;
  final bool hasFitkeyPass;
  final VisitCost fitkey;
  final String? legacyPlanName;

  /// [{id, planName, startsOn, endsOn, state}] at this centre (active / upcoming).
  final List<Json> memberships;
  final bool hasMembership;
}

extension BookingApi on FitkeyApi {
  // ---- Slot booking -----------------------------------------------------------------------------
  Future<VenueAccess> venueAccess(String venueId) async =>
      VenueAccess.fromJson(await client.get('/bookings/venues/$venueId/access'));

  Future<SlotsInfo> venueSlots(String venueId, {String? date}) async =>
      SlotsInfo.fromJson(await client.get('/bookings/venues/$venueId/slots', query: {'date': date}));

  Future<SlotBooking> bookSlot({required String venueId, required String date, required String start}) async {
    final r = await client.post('/bookings', {'venueId': venueId, 'date': date, 'start': start});
    return SlotBooking.fromJson(r['booking']);
  }

  Future<List<SlotBooking>> myBookings({String scope = 'all'}) async =>
      ((await client.get('/bookings/me', query: {'scope': scope}))['bookings'] as List)
          .map((b) => SlotBooking.fromJson(b))
          .toList();

  /// Returns the server's message, e.g. "Cancelled — 120 coins returned to your FitKey pass".
  Future<({bool refunded, String message})> cancelBooking(String id) async {
    final r = await client.post('/bookings/$id/cancel');
    return (refunded: r['refunded'] == true, message: (r['message'] as String?) ?? 'Booking cancelled');
  }

  // ---- Direct memberships -----------------------------------------------------------------------
  Future<List<CentrePlan>> centrePlans(String venueId) async =>
      ((await client.get('/memberships/venues/$venueId/plans'))['plans'] as List)
          .map((p) => CentrePlan.fromJson(p))
          .toList();

  Future<DirectMembership> buyMembership(String planId, {String? startDate}) async {
    final r = await client.post('/memberships', {'planId': planId, 'startDate': ?startDate});
    return DirectMembership.fromJson(r['membership']);
  }

  Future<DirectMembership> renewMembership(String membershipId, {String? startDate}) async {
    final r = await client.post('/memberships/$membershipId/renew', {'startDate': ?startDate});
    return DirectMembership.fromJson(r['membership']);
  }

  Future<({List<DirectMembership> memberships, FitkeyPassSummary pass})> myMemberships() async {
    final r = await client.get('/memberships/me');
    return (
      memberships: (r['memberships'] as List).map((m) => DirectMembership.fromJson(m)).toList(),
      pass: FitkeyPassSummary.fromJson(r['fitkeyPass']),
    );
  }
}
