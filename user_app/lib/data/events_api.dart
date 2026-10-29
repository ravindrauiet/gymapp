import 'fitkey_api.dart';
import 'models.dart';

int _i(dynamic v) => v == null ? 0 : (v as num).toInt();
double _d(dynamic v) => v == null ? 0 : (v as num).toDouble();

/// A FitKey / Org / Partner event (BRD §3.1) — the evolution of [Contest].
class FitEvent {
  FitEvent.fromJson(Json j)
      : id = j['id'],
        title = j['title'],
        description = j['description'],
        kind = j['kind'] ?? 'fitkey',
        format = j['format'] ?? 'virtual',
        metric = j['metric'],
        period = j['period'] ?? 'custom',
        startsOn = DateTime.parse(j['startsOn']),
        endsOn = DateTime.parse(j['endsOn']),
        eventDate = j['eventDate'] == null ? null : DateTime.parse(j['eventDate']),
        reward = j['reward'],
        city = j['city'],
        sponsor = j['sponsor'],
        coverUrl = j['coverUrl'],
        arenaExercise = j['arenaExercise'],
        membersOnly = j['membersOnly'] == true,
        registrationFeePaise = _i(j['registrationFeePaise']),
        orgId = j['orgId'],
        orgName = j['orgName'],
        orgKind = j['orgKind'],
        venue = j['venue'] == null ? null : EventVenue.fromJson(j['venue']),
        battleOrgs = ((j['battleOrgs'] as List?) ?? const []).map((o) => OrgRef.fromJson(o)).toList(),
        participantCount = _i(j['participantCount']),
        joined = j['joined'] == true,
        attended = j['attended'] == true,
        requiresOrg = j['requiresOrg'] == true,
        isMyOrg = j['isMyOrg'] == true,
        status = j['status'] ?? 'live',
        unit = j['unit'] ?? '';

  final String id;
  final String title;
  final String? description;

  /// fitkey | org | partner
  final String kind;

  /// virtual | onground | ai
  final String format;

  /// checkins | running_km | streak | attendance | arena_reps
  final String metric;
  final String period;
  final DateTime startsOn;
  final DateTime endsOn;
  final DateTime? eventDate;
  final String? reward;
  final String? city;
  final String? sponsor;
  final String? coverUrl;
  final String? arenaExercise;
  final bool membersOnly;
  final int registrationFeePaise;
  final String? orgId;
  final String? orgName;
  final String? orgKind;
  final EventVenue? venue;
  final List<OrgRef> battleOrgs;
  final int participantCount;
  final bool joined;
  final bool attended;
  final bool requiresOrg;
  final bool isMyOrg;

  /// live | upcoming | past
  final String status;
  final String unit;

  bool get isBattle => battleOrgs.length > 1;
  bool get finished => status == 'past';
  bool get upcoming => status == 'upcoming';
  int get daysLeft => endsOn.difference(_today()).inDays + 1;
}

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

class EventVenue {
  EventVenue.fromJson(Json j)
      : id = j['id'],
        name = j['name'] ?? 'Venue',
        area = j['area'],
        city = j['city'],
        address = j['address'],
        photo = j['photo'];
  final String id;
  final String name;
  final String? area;
  final String? city;
  final String? address;
  final String? photo;
}

class OrgRef {
  OrgRef.fromJson(Json j)
      : id = j['id'],
        name = j['name'] ?? 'Organisation',
        kind = j['kind'],
        logoUrl = j['logoUrl'];
  final String id;
  final String name;
  final String? kind;
  final String? logoUrl;
  bool get isCollege => kind == 'college';
}

class EventEntry {
  EventEntry.fromJson(Json j)
      : userId = j['userId'],
        name = j['name'],
        city = j['city'],
        orgName = j['orgName'],
        orgId = j['orgId'],
        score = _d(j['score']),
        rank = _i(j['rank']);
  final String userId;
  final String? name;
  final String? city;
  final String? orgId;
  final String? orgName;
  final double score;
  final int rank;

  LeaderEntry toLeaderEntry() =>
      LeaderEntry.fromJson({'userId': userId, 'name': name, 'city': orgName ?? city, 'score': score, 'rank': rank});
}

class EventTeam {
  EventTeam.fromJson(Json j)
      : orgId = j['orgId'],
        name = j['name'] ?? 'Team',
        members = _i(j['members']),
        totalScore = _d(j['totalScore']),
        averageScore = _d(j['averageScore']),
        rank = _i(j['rank']);
  final String orgId;
  final String name;
  final int members;
  final double totalScore;
  final double averageScore;
  final int rank;
}

class EventEligibility {
  EventEligibility.fromJson(Json j)
      : canJoin = j['canJoin'] == true,
        reason = j['reason'],
        message = j['message'],
        orgs = ((j['orgs'] as List?) ?? const []).map((o) => OrgRef.fromJson(o)).toList(),
        eligibleOrgIds = List<String>.from(j['eligibleOrgIds'] ?? const []),
        pendingOrgIds = List<String>.from(j['pendingOrgIds'] ?? const []);

  final bool canJoin;

  /// joined | ended | city | org_verification | org_pending | venue_members | null
  final String? reason;
  final String? message;
  final List<OrgRef> orgs;
  final List<String> eligibleOrgIds;
  final List<String> pendingOrgIds;
}

class EventDetail {
  EventDetail.fromJson(Json j)
      : event = FitEvent.fromJson(j['event']),
        entries = ((j['leaderboard']?['entries'] as List?) ?? const []).map((e) => EventEntry.fromJson(e)).toList(),
        me = j['leaderboard']?['me'] == null ? null : EventEntry.fromJson(j['leaderboard']['me']),
        teams = (j['teams'] as List?)?.map((t) => EventTeam.fromJson(t)).toList(),
        eligibility = EventEligibility.fromJson(j['eligibility'] ?? const {});

  final FitEvent event;
  final List<EventEntry> entries;
  final EventEntry? me;
  final List<EventTeam>? teams;
  final EventEligibility eligibility;

  Leaderboard get leaderboard => Leaderboard.fromJson({
        'entries': [for (final e in entries) _entryJson(e)],
        'me': me == null ? null : _entryJson(me!),
      });

  static Json _entryJson(EventEntry e) =>
      {'userId': e.userId, 'name': e.name, 'city': e.orgName ?? e.city, 'score': e.score, 'rank': e.rank};
}

class OrgMembership {
  OrgMembership.fromJson(Json j)
      : orgId = j['orgId'],
        orgName = j['orgName'] ?? 'Organisation',
        orgKind = j['orgKind'],
        status = j['status'] ?? 'pending',
        method = j['method'],
        workEmail = j['workEmail'],
        reviewNote = j['reviewNote'];
  final String orgId;
  final String orgName;
  final String? orgKind;

  /// pending | verified
  final String status;
  final String? method;
  final String? workEmail;
  final String? reviewNote;
  bool get verified => status == 'verified';
  bool get isCollege => orgKind == 'college';
}

class EventsPage {
  EventsPage(this.events, this.myOrgs);
  final List<FitEvent> events;
  final List<OrgMembership> myOrgs;
}

class PointsEntry {
  PointsEntry.fromJson(Json j)
      : userId = j['userId'],
        name = j['name'],
        city = j['city'],
        score = _d(j['score']),
        rank = j['rank'] == null ? null : _i(j['rank']),
        checkinDays = _i(j['checkinDays']),
        workouts = _i(j['workouts']),
        runningKm = _d(j['runningKm']),
        arenaPoints = _i(j['arenaPoints']);
  final String userId;
  final String? name;
  final String? city;
  final double score;
  final int? rank;
  final int checkinDays;
  final int workouts;
  final double runningKm;
  final int arenaPoints;
}

class TrophyBadge {
  TrophyBadge.fromJson(Json j)
      : id = j['id'],
        title = j['title'],
        description = j['description'] ?? '',
        icon = j['icon'] ?? '',
        earned = j['earned'] == true,
        earnedAt = j['earnedAt'] == null ? null : DateTime.parse(j['earnedAt']).toLocal(),
        progress = _i(j['progress']),
        target = _i(j['target']);
  final String id;
  final String title;
  final String description;
  final String icon;
  final bool earned;
  final DateTime? earnedAt;
  final int progress;
  final int target;
}

class PointsBoard {
  PointsBoard.fromJson(Json j)
      : entries = (j['entries'] as List).map((e) => PointsEntry.fromJson(e)).toList(),
        me = j['me'] == null ? null : PointsEntry.fromJson(j['me']),
        totalRanked = _i(j['totalRanked']),
        badges = ((j['badges'] as List?) ?? const []).map((b) => TrophyBadge.fromJson(b)).toList(),
        earnedCount = _i(j['earnedCount']);
  final List<PointsEntry> entries;
  final PointsEntry? me;
  final int totalRanked;
  final List<TrophyBadge> badges;
  final int earnedCount;

  Leaderboard get leaderboard => Leaderboard.fromJson({
        'entries': [
          for (final e in entries) {'userId': e.userId, 'name': e.name, 'city': e.city, 'score': e.score, 'rank': e.rank},
        ],
        'me': me == null || me!.rank == null
            ? null
            : {'userId': me!.userId, 'name': me!.name, 'city': me!.city, 'score': me!.score, 'rank': me!.rank},
      });
}

extension EventsApi on FitkeyApi {
  /// scope: all | org | open · status: live | upcoming | past
  Future<EventsPage> events({String scope = 'all', String status = 'live', String? query}) async {
    final r = await client.get('/events', query: {'scope': scope, 'status': status, 'q': query});
    return EventsPage(
      (r['events'] as List).map((e) => FitEvent.fromJson(e)).toList(),
      ((r['myOrgs'] as List?) ?? const []).map((m) => OrgMembership.fromJson(m)).toList(),
    );
  }

  Future<EventDetail> event(String id, {String? orgId}) async =>
      EventDetail.fromJson(await client.get('/events/$id', query: {'orgId': orgId}));

  Future<void> joinEvent(String id, {String? orgId}) => client.post('/events/$id/join', {'orgId': ?orgId});

  Future<void> leaveEvent(String id) => client.delete('/events/$id/join');

  Future<List<OrgMembership>> myOrgs() async =>
      ((await client.get('/events/orgs/mine'))['memberships'] as List).map((m) => OrgMembership.fromJson(m)).toList();

  /// Sends a code to a work / college email. Returns the org it matched, and devOtp in development.
  Future<({bool alreadyVerified, String orgName, String? devOtp})> requestOrgEmailOtp(String email, {String? orgId}) async {
    final r = await client.post('/events/orgs/email/request', {'email': email, 'orgId': ?orgId});
    return (
      alreadyVerified: r['alreadyVerified'] == true,
      orgName: (r['org']?['name'] as String?) ?? 'your organisation',
      devOtp: r['devOtp'] as String?,
    );
  }

  Future<OrgMembership> verifyOrgEmail(String email, String otp) async =>
      OrgMembership.fromJson((await client.post('/events/orgs/email/verify', {'email': email, 'otp': otp}))['membership']);

  Future<OrgMembership> joinOrgWithInvite(String code) async =>
      OrgMembership.fromJson((await client.post('/events/orgs/invite', {'code': code}))['membership']);

  Future<OrgMembership> submitOrgId(String orgId, String idProofUrl, {String? department}) async =>
      OrgMembership.fromJson((await client.post('/events/orgs/id-upload', {
        'orgId': orgId,
        'idProofUrl': idProofUrl,
        'department': ?department,
      }))['membership']);

  /// Trophy board. period: week | month.
  Future<PointsBoard> points({String period = 'week', String? city}) async =>
      PointsBoard.fromJson(await client.get('/points', query: {'period': period, 'city': city}));
}
