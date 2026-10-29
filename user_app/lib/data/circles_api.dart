import 'package:dio/dio.dart' show DioMediaType, FormData, MultipartFile;

import 'fitkey_api.dart';
import 'models.dart';

// ---------------------------------------------------------------------------
// Models — Circles (BRD §3.3)
// ---------------------------------------------------------------------------

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
double? _dbl(Object? v) => (v as num?)?.toDouble();

class CircleSession {
  CircleSession.fromJson(Json j)
      : date = j['date'] as String,
        startTime = j['startTime'] as String,
        endTime = j['endTime'] as String,
        status = j['status'] as String,
        specialTitle = (j['special'] as Map?)?['title'] as String?,
        specialKind = (j['special'] as Map?)?['kind'] as String?;

  final String date;
  final String startTime;
  final String endTime;

  /// open | upcoming
  final String status;
  final String? specialTitle;
  final String? specialKind;

  bool get isOpen => status == 'open';
}

class CircleSummary {
  CircleSummary.fromJson(Json j)
      : id = j['id'],
        leaderId = j['leaderId'],
        leaderName = j['leaderName'],
        leaderAvatarUrl = j['leaderAvatarUrl'],
        name = j['name'],
        activity = j['activity'] ?? 'other',
        description = j['description'],
        placeName = j['placeName'] ?? '',
        area = j['area'],
        city = j['city'] ?? '',
        lat = _dbl(j['lat']),
        lng = _dbl(j['lng']),
        days = (j['days'] as List? ?? const []).map((d) => (d as num).toInt()).toList(),
        startTime = j['startTime'] ?? '',
        endTime = j['endTime'] ?? '',
        schedule = j['schedule'] ?? '',
        memberCount = _int(j['memberCount']),
        offlineCount = _int(j['offlineCount']),
        distanceKm = _dbl(j['distanceKm']),
        joined = j['joined'] == true,
        isLeader = j['isLeader'] == true,
        inviteCode = j['inviteCode'],
        streak = _int(j['streak']),
        attendedToday = j['attendedToday'] == true,
        monthCount = _int(j['monthCount']),
        monthSessions = _int(j['monthSessions']),
        nextSession = j['nextSession'] == null ? null : CircleSession.fromJson(Map<String, dynamic>.from(j['nextSession']));

  final String id;
  final String leaderId;
  final String? leaderName;
  final String? leaderAvatarUrl;
  final String name;
  final String activity;
  final String? description;
  final String placeName;
  final String? area;
  final String city;
  final double? lat;
  final double? lng;

  /// ISO weekdays, 1 = Monday … 7 = Sunday.
  final List<int> days;
  final String startTime;
  final String endTime;
  final String schedule;
  final int memberCount;
  final int offlineCount;
  final double? distanceKm;
  final bool joined;
  final bool isLeader;
  final String? inviteCode;

  // Only from /circles/mine
  final int streak;
  final bool attendedToday;
  final int monthCount;
  final int monthSessions;
  final CircleSession? nextSession;

  int get headcount => memberCount + offlineCount;
  String get where => [placeName, if (area != null && area!.isNotEmpty) area!, city].join(', ');
}

class CircleToday {
  CircleToday.fromJson(Json j)
      : isSessionDay = j['isSessionDay'] == true,
        status = j['status'] ?? 'none',
        startTime = j['startTime'],
        endTime = j['endTime'],
        opensAt = j['opensAt'],
        closesAt = j['closesAt'],
        specialTitle = (j['special'] as Map?)?['title'] as String?,
        attendeeCount = _int(j['attendeeCount']);

  final bool isSessionDay;

  /// none | upcoming | open | over
  final String status;
  final String? startTime;
  final String? endTime;
  final String? opensAt;
  final String? closesAt;
  final String? specialTitle;
  final int attendeeCount;
}

class CircleMyStats {
  CircleMyStats.fromJson(Json j)
      : streak = _int(j['streak']),
        missedInRow = _int(j['missedInRow']),
        attendedToday = j['attendedToday'] == true,
        monthCount = _int(j['monthCount']),
        monthSessions = _int(j['monthSessions']),
        lastAttended = j['lastAttended'];

  final int streak;
  final int missedInRow;
  final bool attendedToday;
  final int monthCount;
  final int monthSessions;
  final String? lastAttended;
}

class CircleSpecial {
  CircleSpecial.fromJson(Json j)
      : id = j['id'],
        title = j['title'],
        kind = j['kind'] ?? 'special',
        date = j['sessionDate'],
        startTime = j['startTime'],
        endTime = j['endTime'],
        note = j['note'],
        rsvpCount = _int(j['rsvpCount']),
        going = j['going'] == true;

  final String id;
  final String title;

  /// special | festival | yoga_day | health_camp
  final String kind;
  final String date;
  final String? startTime;
  final String? endTime;
  final String? note;
  final int rsvpCount;
  final bool going;
}

class CircleRegular {
  CircleRegular.fromJson(Json j)
      : name = j['name'] ?? 'Member',
        avatarUrl = j['avatarUrl'],
        sessions = _int(j['sessions']),
        offline = j['offlineMemberId'] != null;

  final String name;
  final String? avatarUrl;
  final int sessions;
  final bool offline;
}

class CircleDetail {
  CircleDetail.fromJson(Json j)
      : circle = CircleSummary.fromJson(Map<String, dynamic>.from(j['circle'])),
        today = CircleToday.fromJson(Map<String, dynamic>.from(j['today'])),
        nextSession = j['nextSession'] == null ? null : CircleSession.fromJson(Map<String, dynamic>.from(j['nextSession'])),
        me = j['me'] == null ? null : CircleMyStats.fromJson(Map<String, dynamic>.from(j['me'])),
        specials = (j['specials'] as List? ?? const []).map((s) => CircleSpecial.fromJson(Map<String, dynamic>.from(s))).toList(),
        regularThisMonth = (j['mostRegular'] as Map?)?['thisMonth'] == null
            ? null
            : CircleRegular.fromJson(Map<String, dynamic>.from(j['mostRegular']['thisMonth'])),
        regularLastMonth = (j['mostRegular'] as Map?)?['lastMonth'] == null
            ? null
            : CircleRegular.fromJson(Map<String, dynamic>.from(j['mostRegular']['lastMonth'])),
        cityRank = j['cityRank'] == null ? null : _int(j['cityRank']['rank']),
        cityTotal = j['cityRank'] == null ? null : _int(j['cityRank']['total']),
        cityRate = j['cityRank'] == null ? null : _dbl(j['cityRank']['rate']),
        circleOfTheMonth = j['circleOfTheMonth'] == true;

  final CircleSummary circle;
  final CircleToday today;
  final CircleSession? nextSession;
  final CircleMyStats? me;
  final List<CircleSpecial> specials;
  final CircleRegular? regularThisMonth;
  final CircleRegular? regularLastMonth;
  final int? cityRank;
  final int? cityTotal;
  final double? cityRate;
  final bool circleOfTheMonth;
}

class CircleMember {
  CircleMember.fromJson(Json j, {required this.offline})
      : id = offline ? j['id'] : j['userId'],
        name = j['name'] ?? 'Member',
        avatarUrl = j['avatarUrl'],
        role = j['role'] ?? 'member',
        phone = j['phone'],
        streak = _int(j['streak']),
        attendedToday = j['attendedToday'] == true,
        monthCount = _int(j['monthCount']),
        monthSessions = _int(j['monthSessions']);

  /// userId for app members, offline-member id otherwise.
  final String id;
  final bool offline;
  final String name;
  final String? avatarUrl;
  final String role;
  final String? phone;
  final int streak;
  final bool attendedToday;
  final int monthCount;
  final int monthSessions;

  bool get isLeader => role == 'leader';
}

class CircleRoster {
  CircleRoster.fromJson(Json j)
      : today = CircleToday.fromJson(Map<String, dynamic>.from(j['today'])),
        members = (j['members'] as List).map((m) => CircleMember.fromJson(Map<String, dynamic>.from(m), offline: false)).toList(),
        offlineMembers =
            (j['offlineMembers'] as List).map((m) => CircleMember.fromJson(Map<String, dynamic>.from(m), offline: true)).toList();

  final CircleToday today;
  final List<CircleMember> members;
  final List<CircleMember> offlineMembers;
}

class CircleMessage {
  CircleMessage.fromJson(Json j)
      : id = j['id'],
        userId = j['userId'],
        userName = j['userName'],
        avatarUrl = j['avatarUrl'],
        body = j['body'],
        audioUrl = j['audioUrl'],
        audioSeconds = (j['audioSeconds'] as num?)?.toInt(),
        rawCreatedAt = j['createdAt'],
        createdAt = DateTime.parse(j['createdAt']).toLocal(),
        mine = j['mine'] == true;

  final String id;
  final String userId;
  final String? userName;
  final String? avatarUrl;
  final String? body;
  final String? audioUrl;
  final int? audioSeconds;
  final String rawCreatedAt;
  final DateTime createdAt;
  final bool mine;
}

class CircleBoardEntry {
  CircleBoardEntry.fromJson(Json j)
      : circleId = j['circleId'],
        name = j['name'],
        area = j['area'],
        city = j['city'] ?? '',
        activity = j['activity'] ?? 'other',
        members = _int(j['members']),
        sessions = _int(j['sessions']),
        attendances = _int(j['attendances']),
        rate = _dbl(j['rate']) ?? 0,
        rank = _int(j['rank']),
        month = j['month'];

  final String circleId;
  final String name;
  final String? area;
  final String city;
  final String activity;
  final int members;
  final int sessions;
  final int attendances;
  final double rate;
  final int rank;
  final String? month;
}

class CircleBoard {
  CircleBoard.fromJson(Json j)
      : city = j['city'],
        month = j['month'],
        entries = (j['entries'] as List).map((e) => CircleBoardEntry.fromJson(Map<String, dynamic>.from(e))).toList(),
        circleOfTheMonth =
            j['circleOfTheMonth'] == null ? null : CircleBoardEntry.fromJson(Map<String, dynamic>.from(j['circleOfTheMonth']));

  final String? city;
  final String month;
  final List<CircleBoardEntry> entries;
  final CircleBoardEntry? circleOfTheMonth;
}

class FamilyCircle {
  FamilyCircle.fromJson(Json j)
      : circleId = j['circleId'],
        name = j['name'],
        activity = j['activity'] ?? 'other',
        placeName = j['placeName'] ?? '',
        schedule = j['schedule'] ?? '',
        streak = _int(j['streak']),
        missedInRow = _int(j['missedInRow']),
        attendedToday = j['attendedToday'] == true,
        lastAttended = j['lastAttended'],
        monthCount = _int(j['monthCount']),
        monthSessions = _int(j['monthSessions']);

  final String circleId;
  final String name;
  final String activity;
  final String placeName;
  final String schedule;
  final int streak;
  final int missedInRow;
  final bool attendedToday;
  final String? lastAttended;
  final int monthCount;
  final int monthSessions;
}

class FamilyPerson {
  FamilyPerson.fromJson(Json j)
      : userId = j['userId'],
        name = j['name'],
        avatarUrl = j['avatarUrl'],
        circles = (j['circles'] as List? ?? const []).map((c) => FamilyCircle.fromJson(Map<String, dynamic>.from(c))).toList();

  final String userId;
  final String? name;
  final String? avatarUrl;
  final List<FamilyCircle> circles;
}

class FamilyOverview {
  FamilyOverview.fromJson(Json j)
      : code = j['code'],
        following = (j['following'] as List).map((p) => FamilyPerson.fromJson(Map<String, dynamic>.from(p))).toList(),
        followers = (j['followers'] as List).map((p) => FamilyPerson.fromJson(Map<String, dynamic>.from(p))).toList();

  final String code;
  final List<FamilyPerson> following;
  final List<FamilyPerson> followers;
}

class CircleAttendResult {
  CircleAttendResult.fromJson(Json j)
      : circleId = j['circleId'],
        circleName = j['circleName'] ?? 'your circle',
        streak = _int(j['streak']),
        joinedNow = j['joinedNow'] == true;

  final String circleId;
  final String circleName;
  final int streak;
  final bool joinedNow;
}

// ---------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------

extension CirclesApi on FitkeyApi {
  Future<List<CircleSummary>> myCircles() async => ((await client.get('/circles/mine'))['circles'] as List)
      .map((c) => CircleSummary.fromJson(Map<String, dynamic>.from(c)))
      .toList();

  /// "Circles near me": distance-sorted with [lat]/[lng], else the [city] (or the profile city).
  Future<({String mode, String? city, List<CircleSummary> circles})> nearbyCircles(
      {double? lat, double? lng, String? city, String? q}) async {
    final r = await client.get('/circles/nearby', query: {'lat': lat, 'lng': lng, 'city': city, 'q': q});
    return (
      mode: r['mode'] as String,
      city: r['city'] as String?,
      circles: (r['circles'] as List).map((c) => CircleSummary.fromJson(Map<String, dynamic>.from(c))).toList(),
    );
  }

  Future<CircleBoard> circleLeaderboard({String? city}) async =>
      CircleBoard.fromJson(await client.get('/circles/leaderboard', query: {'city': city}));

  Future<CircleDetail> circle(String id) async => CircleDetail.fromJson(await client.get('/circles/$id'));

  Future<CircleSummary> createCircle(Json fields) async =>
      CircleSummary.fromJson(Map<String, dynamic>.from((await client.post('/circles', fields))['circle']));

  Future<CircleSummary> updateCircle(String id, Json fields) async =>
      CircleSummary.fromJson(Map<String, dynamic>.from((await client.patch('/circles/$id', fields))['circle']));

  Future<void> closeCircle(String id) => client.delete('/circles/$id');

  Future<String> joinCircleByCode(String code) async => (await client.post('/circles/join', {'code': code}))['circleId'] as String;

  Future<void> joinCircle(String id) => client.post('/circles/$id/join');

  Future<void> leaveCircle(String id) => client.post('/circles/$id/leave');

  /// Scanned QR poster → marks today's attendance (joins the circle if needed).
  Future<CircleAttendResult> attendCircleQr(String qr) async =>
      CircleAttendResult.fromJson(await client.post('/circles/attend', {'qr': qr}));

  /// One-tap "I'm here" using the phone's location.
  Future<CircleAttendResult> attendCircleHere(String id, {required double lat, required double lng}) async =>
      CircleAttendResult.fromJson(await client.post('/circles/$id/attend', {'lat': lat, 'lng': lng}));

  Future<CircleRoster> circleMembers(String id) async => CircleRoster.fromJson(await client.get('/circles/$id/members'));

  Future<void> removeCircleMember(String id, String userId) => client.delete('/circles/$id/members/$userId');

  Future<void> addOfflineMember(String id, {required String name, String? phone}) =>
      client.post('/circles/$id/offline-members', {'name': name, 'phone': phone});

  Future<void> removeOfflineMember(String id, String memberId) => client.delete('/circles/$id/offline-members/$memberId');

  /// Leader marks (or unmarks) a member present today.
  Future<void> markCircleAttendance(String id, {required CircleMember member, required bool present}) =>
      client.post('/circles/$id/attendance/mark', {
        if (member.offline) 'offlineMemberId': member.id else 'userId': member.id,
        'present': present,
      });

  Future<({String qr, int version})> circleQr(String id, {bool rotate = false}) async {
    final r = rotate ? await client.post('/circles/$id/qr/rotate') : await client.get('/circles/$id/qr');
    return (qr: r['qr'] as String, version: (r['version'] as num).toInt());
  }

  Future<void> createCircleSpecial(String id, Json fields) => client.post('/circles/$id/specials', fields);

  Future<void> deleteCircleSpecial(String id, String specialId) => client.delete('/circles/$id/specials/$specialId');

  Future<int> rsvpCircleSpecial(String specialId, {required bool going}) async =>
      _int((await client.post('/circles/specials/$specialId/rsvp', {'going': going}))['rsvpCount']);

  Future<List<CircleMessage>> circleMessages(String id, {String? after}) async =>
      ((await client.get('/circles/$id/messages', query: {'after': after}))['messages'] as List)
          .map((m) => CircleMessage.fromJson(Map<String, dynamic>.from(m)))
          .toList();

  Future<CircleMessage> sendCircleMessage(String id, {String? body, String? audioUrl, int? audioSeconds}) async =>
      CircleMessage.fromJson(Map<String, dynamic>.from((await client.post('/circles/$id/messages', {
        'body': ?body,
        'audioUrl': ?audioUrl,
        'audioSeconds': ?audioSeconds,
      }))['message']));

  /// Uploads a recorded voice note (AAC in an .m4a container) and returns its server-relative URL.
  Future<String> uploadVoiceNote(List<int> bytes) async {
    final r = await client.post(
      '/uploads',
      FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: 'voice-note.m4a', contentType: DioMediaType('audio', 'mp4')),
      }),
    );
    return r['url'] as String;
  }

  Future<FamilyOverview> circleFamily() async => FamilyOverview.fromJson(await client.get('/circles/family'));

  Future<String> rotateFamilyCode() async => (await client.post('/circles/family/code/rotate'))['code'] as String;

  Future<void> linkFamily(String code) => client.post('/circles/family/link', {'code': code});

  Future<void> unlinkFamily(String userId) => client.delete('/circles/family/$userId');
}
