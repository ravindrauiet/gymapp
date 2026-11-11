import 'package:fitkey_core/fitkey_core.dart' show ApiException;

import 'fitkey_api.dart';
import 'models.dart';
import 'venue_hours.dart';

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
        available = j['available'] == true,
        passBlocked = j['passBlocked'] == true,
        ladiesOnly = j['ladiesOnly'] == true,
        closed = j['blocked'] == true || j['closed'] == true,
        passFull = j['passFull'] == true ||
            (j['passCap'] != null && j['passBooked'] != null && _i(j['passBooked']) >= _i(j['passCap'])),
        note = (j['note'] ?? j['blockNote']) as String?;
  final String start;
  final String end;
  final int capacity;
  final int booked;
  final int left;
  final bool past;
  final bool available;

  /// Inside a window where the centre doesn't take the FitKey pass (its own members can still book).
  final bool passBlocked;
  final bool ladiesOnly;

  /// Closed by the centre (holiday / blocked slot / outside hours).
  final bool closed;

  /// Every FitKey-pass spot in this slot is taken (the centre caps pass users per slot).
  final bool passFull;
  final String? note;
}

/// What the member can do with one slot, given how they would pay ([cost]).
enum SlotState { available, past, full, closed, passBlocked, passFull }

/// Pass blocks and pass caps only apply when the visit would be paid with the FitKey pass (coins / session /
/// legacy pass); a direct membership at the centre is never blocked.
SlotState slotStateFor(Slot s, VisitCost cost) {
  final viaPass = cost.method != 'membership';
  if (s.closed) return SlotState.closed;
  if (s.past) return SlotState.past;
  if (viaPass && s.passBlocked) return SlotState.passBlocked;
  if (s.left <= 0) return SlotState.full;
  if (viaPass && s.passFull) return SlotState.passFull;
  if (!s.available && !s.passBlocked && !s.passFull) return SlotState.full;
  return SlotState.available;
}

/// Short label under a slot's time.
String slotStateLabel(SlotState state, Slot s) => switch (state) {
      SlotState.closed => 'Closed',
      SlotState.past => 'Started',
      SlotState.passBlocked => 'Pass not valid',
      SlotState.full => 'Full',
      SlotState.passFull => 'Pass spots full',
      SlotState.available => s.left <= 5 ? 'Only ${s.left} left' : '${s.left} left',
    };

/// A friendly title + message for a failed booking / check-in, from the server's 409 `code`.
({String title, String message})? bookingProblem(Object e, {String? venueName}) {
  if (e is! ApiException) return null;
  final own = venueName == null ? 'the centre\'s own membership' : 'a $venueName membership';
  return switch (e.code) {
    'PASS_BLOCKED' => (
        title: 'FitKey pass not valid at this time',
        message: e.message.isNotEmpty
            ? e.message
            : 'This centre does not take the FitKey pass in this slot. Pick another time, or book with $own.',
      ),
    'VENUE_CLOSED' => (
        title: 'Closed at this time',
        message: 'The centre is closed for this slot (holiday, blocked slot or outside opening hours). '
            'Please pick another time or day.',
      ),
    'PASS_SLOT_FULL' => (
        title: 'FitKey pass spots are full',
        message: 'All FitKey pass spots in this slot are taken. Try another slot, or book with $own.',
      ),
    _ => null,
  };
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
        freeCancelHours = _i(j['freeCancelHours']),
        slotMinutes = _iOrNull(j['slotMinutes'] ?? j['venue']['slotMinutes']),
        autoAccept = (j['autoAcceptBookings'] ?? j['venue']['autoAcceptBookings']) as bool?,
        passBlockLabels = _s(j['passBlockLabels'] ?? j['venue']['passBlockLabels']);
  final int? slotMinutes;

  /// False when the centre confirms each booking itself (it comes back as `requested`). Null = not sent.
  final bool? autoAccept;
  final List<String> passBlockLabels;
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
        freeCancel = j['freeCancel'] == true,
        rejectReason = j['rejectReason'] as String?;
  final String id;
  final String venueId;
  final String venueName;
  final String? venueArea;
  final List<String> venueCategories;
  final String? venueCoverPhoto;
  final String slotDate;
  final String slotStart;
  final String slotEnd;

  /// requested (waiting for the centre) | booked | attended | cancelled | rejected (declined by the centre)
  final String status;
  final String? rejectReason;

  bool get isRequested => status == 'requested';

  /// coins | session | membership | legacy
  final String? paidVia;
  final String? costLabel;
  final bool refunded;
  final DateTime? startsAt;
  final bool canCancel;
  final bool freeCancel;
}

/// "Awaiting confirmation", "Declined by venue", "Booked", "Missed", "Attended", "Cancelled · refunded".
String bookingStatusLabel(String status, {bool canCancel = false, bool refunded = false}) => switch (status) {
      'requested' => 'Awaiting confirmation',
      'rejected' => 'Declined by venue',
      'attended' => 'Attended',
      'cancelled' => refunded ? 'Cancelled · refunded' : 'Cancelled',
      _ => canCancel ? 'Booked' : 'Missed',
    };

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
        maxVisitsPerWeek = _iOrNull(j['maxVisitsPerWeek']),
        slotLimitNote = j['slotLimitNote'] as String?;
  final String id;
  final String venueId;
  final String name;
  final String? description;

  /// hourly | day | weekly | monthly | quarterly | yearly ('annual' = legacy yearly)
  final String duration;

  /// Free-text slot rule from the centre, e.g. "Mornings only (6–11 AM)".
  final String? slotLimitNote;

  /// "1 hour", "1 day", "7 days", "1 year" …
  String get validityLabel => planValidityLabel(duration, durationDays);
  final int durationDays;
  final int pricePaise;
  final int effectivePricePaise;
  final int offerPct;
  final List<String> inclusions;
  final int? maxVisitsPerDay;
  final int? maxVisitsPerWeek;

  String get durationLabel => durationLabelOf(duration);

  String? get limitsLabel => planLimitsLabel(maxVisitsPerDay, maxVisitsPerWeek, slotLimitNote);
}

/// "1 visit/day · 4 visits/week · Mornings only" — null when the plan has no slot limits.
String? planLimitsLabel(int? perDay, int? perWeek, [String? note]) {
  final parts = [
    if (perDay != null) '$perDay visit${perDay == 1 ? '' : 's'}/day',
    if (perWeek != null) '$perWeek visit${perWeek == 1 ? '' : 's'}/week',
    if (note != null && note.trim().isNotEmpty) note.trim(),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String durationLabelOf(String d) =>
    const {
      'hourly': 'Hourly',
      'day': 'Day pass',
      'weekly': 'Weekly',
      'monthly': 'Monthly',
      'quarterly': 'Quarterly',
      'yearly': 'Yearly',
      'annual': 'Yearly',
    }[d] ??
    (d.isEmpty ? d : d[0].toUpperCase() + d.substring(1));

/// How long one purchase lasts: hourly → "1 hour", day → "1 day", weekly → "7 days", yearly → "1 year".
String planValidityLabel(String duration, int durationDays) {
  if (duration == 'hourly') return '1 hour';
  if ((duration == 'yearly' || duration == 'annual') && (durationDays == 0 || durationDays >= 365)) return '1 year';
  final d = durationDays > 0 ? durationDays : (duration == 'weekly' ? 7 : 1);
  return '$d day${d == 1 ? '' : 's'}';
}

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

/// The member's own short-lived QR for the centre to scan (BRD §10.1). [code] is already the full payload.
class MemberQr {
  MemberQr.fromJson(Json j)
      : code = j['code'] as String,
        expiresAt = _dOrNull(j['expiresAt']) ?? DateTime.now().add(const Duration(minutes: 1));
  final String code;
  final DateTime expiresAt;
}

extension BookingApi on FitkeyApi {
  /// GET /venues/:id with the Partner BRD extras (sports, video, per-day hours, pass blocks, closures).
  Future<({Venue venue, List<PlanRef> plans, VenueTimings timings})> venueWithTimings(String id) async {
    final r = await client.get('/venues/$id');
    return (
      venue: Venue.fromJson(r['venue']),
      plans: ((r['plans'] as List?) ?? const []).map((p) => PlanRef.fromJson(p)).toList(),
      timings: VenueTimings.fromJson(Json.from(r['venue'] as Map)),
    );
  }

  /// GET /checkins/member-qr → { code, expiresAt }.
  Future<MemberQr> memberQr() async => MemberQr.fromJson(await client.get('/checkins/member-qr'));

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
