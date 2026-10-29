import 'models.dart' show Json;
import 'partner_api.dart';

// Partner insights: ratings dashboard, partner events and notifications.
// Endpoints: /ratings/partner/*, /events/partner/*, /notifications.

double? _d(dynamic v) => v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
int _i(dynamic v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
String? _s(dynamic v) => v is String && v.isNotEmpty ? v : null;
List<String> _strings(dynamic v) => (v as List? ?? const []).map((e) => e.toString()).toList();
DateTime? _date(dynamic v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

/// A date-only value ("2026-11-05") as a local midnight DateTime.
DateTime? _day(dynamic v) {
  if (v is! String || v.length < 10) return null;
  final p = v.substring(0, 10).split('-').map(int.tryParse).toList();
  if (p.length != 3 || p.contains(null)) return null;
  return DateTime(p[0]!, p[1]!, p[2]!);
}

// ---------------------------------------------------------------------------
// Ratings
// ---------------------------------------------------------------------------

/// Sub-rating labels shown to partners (keys from the backend's SUB_RATINGS).
const subRatingLabels = <String, String>{
  'cleanliness': 'Cleanliness',
  'equipment': 'Equipment',
  'staff': 'Staff',
  'crowd': 'Crowd',
  'value': 'Value for money',
  'knowledge': 'Knowledge',
  'punctuality': 'Punctuality',
  'communication': 'Communication',
  'results': 'Results',
};

/// A venue or the trainer profile that members can rate.
class RatingTarget {
  RatingTarget.fromJson(Json j, {required this.isTrainer})
      : id = j['id'],
        name = j['name'] ?? (isTrainer ? 'Trainer profile' : 'Venue'),
        area = _s(j['area']),
        city = _s(j['city']),
        photoUrl = _s(j['photoUrl']),
        categories = _strings(j['categories']),
        status = _s(j['status']),
        avg = _d(j['avg']),
        count = _i(j['count']),
        isNew = j['isNew'] != false;

  final bool isTrainer;
  final String id;
  final String name;
  final String? area;
  final String? city;
  final String? photoUrl;
  final List<String> categories;
  final String? status;
  final double? avg;
  final int count;
  final bool isNew;

  String get subtitle => isTrainer ? 'Your trainer profile' : [area, city].whereType<String>().join(', ');
}

class RatingTargets {
  RatingTargets.fromJson(Json j)
      : venues = (j['venues'] as List? ?? const []).map((v) => RatingTarget.fromJson(v, isTrainer: false)).toList(),
        trainer = j['trainer'] == null ? null : RatingTarget.fromJson(j['trainer'], isTrainer: true),
        newUntil = _i(j['newUntil']) == 0 ? 5 : _i(j['newUntil']);

  final List<RatingTarget> venues;
  final RatingTarget? trainer;
  final int newUntil;

  List<RatingTarget> get all => [...venues, ?trainer];
}

class SubRatingStat {
  const SubRatingStat(this.key, this.avg, this.count);
  final String key;
  final double avg;
  final int count;
  String get label => subRatingLabels[key] ?? key;
}

class RatingTrendPoint {
  RatingTrendPoint.fromJson(Json j)
      : month = _day('${j['month']}-01') ?? DateTime.now(),
        avg = _d(j['avg']),
        count = _i(j['count']);
  final DateTime month;
  final double? avg;
  final int count;
}

class RatingsSummary {
  RatingsSummary.fromJson(Json j)
      : avg = _d(j['avg']),
        count = _i(j['count']),
        isNew = j['isNew'] != false,
        newUntil = _i(j['newUntil']) == 0 ? 5 : _i(j['newUntil']),
        distribution = {
          for (var s = 1; s <= 5; s++) s: _i((j['distribution'] as Map?)?['$s']),
        },
        subRatingKeys = _strings(j['subRatingKeys']),
        subRatings = {
          for (final e in ((j['subRatings'] as Map?) ?? const {}).entries)
            e.key as String: SubRatingStat(e.key as String, _d((e.value as Map)['avg']) ?? 0, _i((e.value as Map)['count'])),
        },
        trend = (j['trend'] as List? ?? const []).map((t) => RatingTrendPoint.fromJson(t)).toList(),
        last30Avg = _d((j['last30Days'] as Map?)?['avg']),
        last30Count = _i((j['last30Days'] as Map?)?['count']),
        previousAvg = _d((j['last30Days'] as Map?)?['previousAvg']);

  final double? avg;
  final int count;
  final bool isNew;
  final int newUntil;
  final Map<int, int> distribution;
  final List<String> subRatingKeys;
  final Map<String, SubRatingStat> subRatings;
  final List<RatingTrendPoint> trend;
  final double? last30Avg;
  final int last30Count;

  /// Average of ratings 30–60 days ago (for the "vs last month" delta).
  final double? previousAvg;
}

class RatingEntry {
  RatingEntry.fromJson(Json j)
      : stars = _i(j['stars']),
        member = _s(j['member']) ?? 'FitKey member',
        subRatings = {
          for (final e in ((j['subRatings'] as Map?) ?? const {}).entries) e.key as String: _i(e.value),
        },
        updatedAt = _date(j['updatedAt']) ?? DateTime.now(),
        edited = j['edited'] == true,
        rawUpdatedAt = j['updatedAt'] as String?;

  final int stars;

  /// Masked first name, e.g. "R•••". Members stay anonymous.
  final String member;
  final Map<String, int> subRatings;
  final DateTime updatedAt;
  final bool edited;
  final String? rawUpdatedAt;
}

class RatingsPage {
  RatingsPage.fromJson(Json j)
      : ratings = (j['ratings'] as List? ?? const []).map((r) => RatingEntry.fromJson(r)).toList(),
        nextBefore = j['nextBefore'] as String?;
  final List<RatingEntry> ratings;
  final String? nextBefore;
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

enum EventFormat {
  virtual('Virtual', 'Members compete from anywhere — check-ins, running or streaks'),
  onground('On-ground', 'At your venue on the day — attendance via your front-desk QR'),
  ai('AI-verified', 'Reps counted by the FitKey AI Arena camera');

  const EventFormat(this.label, this.blurb);
  final String label;
  final String blurb;

  static EventFormat parse(String? s) => EventFormat.values.firstWhere((f) => f.name == s, orElse: () => EventFormat.virtual);
}

const eventMetricLabels = <String, String>{
  'checkins': 'Most check-in days',
  'running_km': 'Most km run',
  'streak': 'Longest check-in streak',
  'attendance': 'Attendance',
  'arena_reps': 'Best AI-counted set',
};

/// AI Arena exercises (ids from backend routes/arena.js).
const arenaExercises = <String, String>{
  'pushups': 'Push-ups',
  'squats': 'Squats',
  'pullups': 'Pull-ups',
  'burpees': 'Burpees',
  'plank': 'Plank',
};

class EventVenue {
  EventVenue.fromJson(Json j)
      : id = j['id'],
        name = j['name'] ?? 'Venue',
        area = _s(j['area']),
        city = _s(j['city']),
        address = _s(j['address']),
        photo = _s(j['photo']),
        categories = _strings(j['categories']),
        status = _s(j['status']);
  final String id;
  final String name;
  final String? area;
  final String? city;
  final String? address;
  final String? photo;
  final List<String> categories;
  final String? status;
  String get location => [area, city].whereType<String>().join(', ');
}

class PartnerEvent {
  PartnerEvent.fromJson(Json j)
      : id = j['id'],
        title = j['title'] ?? 'Event',
        description = _s(j['description']),
        kind = j['kind'] ?? 'partner',
        format = EventFormat.parse(j['format']),
        metric = j['metric'] ?? 'checkins',
        unit = j['unit'] ?? '',
        startsOn = _day(j['startsOn']) ?? DateTime.now(),
        endsOn = _day(j['endsOn']) ?? DateTime.now(),
        eventDate = _day(j['eventDate']),
        reward = _s(j['reward']),
        sponsor = _s(j['sponsor']),
        city = _s(j['city']),
        membersOnly = j['membersOnly'] == true,
        arenaExercise = _s(j['arenaExercise']),
        coverUrl = _s(j['coverUrl']),
        status = j['status'] ?? 'upcoming',
        participantCount = _i(j['participantCount']),
        attendedCount = _i(j['attendedCount']),
        canEdit = j['canEdit'] == true,
        venue = EventVenue.fromJson((j['venue'] as Map?)?.cast<String, dynamic>() ?? {'id': j['venueId']});

  final String id;
  final String title;
  final String? description;
  final String kind;
  final EventFormat format;
  final String metric;
  final String unit;
  final DateTime startsOn;
  final DateTime endsOn;
  final DateTime? eventDate;
  final String? reward;
  final String? sponsor;
  final String? city;
  final bool membersOnly;
  final String? arenaExercise;
  final String? coverUrl;

  /// live | upcoming | past
  final String status;
  final int participantCount;
  final int attendedCount;
  final bool canEdit;
  final EventVenue venue;

  bool get isPast => status == 'past';
  String get metricLabel => metric == 'arena_reps' && arenaExercise != null
      ? 'Best set of ${arenaExercises[arenaExercise] ?? arenaExercise}'
      : eventMetricLabels[metric] ?? metric;
}

class PartnerEventList {
  PartnerEventList.fromJson(Json j)
      : events = (j['events'] as List? ?? const []).map((e) => PartnerEvent.fromJson(e)).toList(),
        live = _i((j['counts'] as Map?)?['live']),
        upcoming = _i((j['counts'] as Map?)?['upcoming']),
        past = _i((j['counts'] as Map?)?['past']);
  final List<PartnerEvent> events;
  final int live;
  final int upcoming;
  final int past;
}

class EventLeaderboardEntry {
  EventLeaderboardEntry.fromJson(Json j)
      : userId = j['userId'] ?? '',
        name = _s(j['name']) ?? 'FitKey member',
        city = _s(j['city']),
        avatarUrl = _s(j['avatarUrl']),
        score = _d(j['score']) ?? 0,
        rank = _i(j['rank']),
        attended = j['attendedAt'] != null;
  final String userId;
  final String name;
  final String? city;
  final String? avatarUrl;
  final double score;
  final int rank;
  final bool attended;
}

class EventParticipant {
  EventParticipant.fromJson(Json j)
      : userId = j['userId'] ?? '',
        name = _s(j['name']) ?? 'FitKey member',
        city = _s(j['city']),
        avatarUrl = _s(j['avatarUrl']),
        joinedAt = _date(j['joinedAt']),
        attendedAt = _date(j['attendedAt']);
  final String userId;
  final String name;
  final String? city;
  final String? avatarUrl;
  final DateTime? joinedAt;
  final DateTime? attendedAt;
  bool get attended => attendedAt != null;
}

class PartnerEventDetail {
  PartnerEventDetail({required this.event, required this.leaderboard, required this.participants});
  final PartnerEvent event;
  final List<EventLeaderboardEntry> leaderboard;
  final List<EventParticipant> participants;
}

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------

class PartnerNotification {
  PartnerNotification.fromJson(Json j)
      : id = j['id'],
        type = j['type'] ?? '',
        title = j['title'] ?? '',
        body = _s(j['body']),
        data = (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
        read = j['readAt'] != null,
        createdAt = _date(j['createdAt']) ?? DateTime.now(),
        rawCreatedAt = j['createdAt'] as String?;
  final String id;
  final String type;
  final String title;
  final String? body;
  final Json data;
  final bool read;
  final DateTime createdAt;
  final String? rawCreatedAt;
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

extension InsightsApi on PartnerApi {
  // Ratings
  Future<RatingTargets> ratingTargets() async => RatingTargets.fromJson(await client.get('/ratings/partner/targets'));

  /// Summary for one of my venues, or my trainer profile when [venueId] is null.
  Future<RatingsSummary> ratingsSummary({String? venueId}) async => RatingsSummary.fromJson(
      (await client.get(venueId == null ? '/ratings/partner/trainer' : '/ratings/partner/venues/$venueId'))['summary']);

  Future<RatingsPage> ratingsFeed({String? venueId, String? before, int limit = 20}) async => RatingsPage.fromJson(
        await client.get(
          venueId == null ? '/ratings/partner/trainer/ratings' : '/ratings/partner/venues/$venueId/ratings',
          query: {'before': before, 'limit': limit},
        ),
      );

  // Events
  Future<PartnerEventList> partnerEvents({String status = 'any', String? venueId}) async =>
      PartnerEventList.fromJson(await client.get('/events/partner/events', query: {'status': status, 'venueId': venueId}));

  Future<PartnerEventDetail> partnerEvent(String id) async {
    final results = await Future.wait([
      client.get('/events/partner/events/$id'),
      client.get('/events/partner/events/$id/participants'),
    ]);
    return PartnerEventDetail(
      event: PartnerEvent.fromJson(results[0]['event']),
      leaderboard: ((results[0]['leaderboard'] as Map?)?['entries'] as List? ?? const [])
          .map((e) => EventLeaderboardEntry.fromJson(e))
          .toList(),
      participants: (results[1]['participants'] as List? ?? const []).map((e) => EventParticipant.fromJson(e)).toList(),
    );
  }

  Future<PartnerEvent> createPartnerEvent(Json fields) async =>
      PartnerEvent.fromJson((await client.post('/events/partner/events', fields))['event']);

  /// Returns the updated event and how many registered members were notified.
  Future<({PartnerEvent event, int notified})> updatePartnerEvent(String id, Json fields) async {
    final r = await client.patch('/events/partner/events/$id', fields);
    return (event: PartnerEvent.fromJson(r['event']), notified: _i(r['notified']));
  }

  /// Cancels the event; returns how many registered members were notified.
  Future<int> deletePartnerEvent(String id) async => _i((await client.delete('/events/partner/events/$id'))['notified']);

  // Notifications
  Future<({List<PartnerNotification> items, int unread})> notifications({String? before}) async {
    final r = await client.get('/notifications', query: {'before': before});
    return (
      items: (r['notifications'] as List? ?? const []).map((n) => PartnerNotification.fromJson(n)).toList(),
      unread: _i(r['unread']),
    );
  }

  Future<int> unreadNotifications() async => _i((await client.get('/notifications/unread-count'))['unread']);

  Future<void> markNotificationsRead({List<String>? ids}) => client.post('/notifications/read', {'ids': ?ids});
}

