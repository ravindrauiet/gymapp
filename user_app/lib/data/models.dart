// Typed views over the FITKEY API's JSON (camelCase keys).

typedef Json = Map<String, dynamic>;

List<String> _strings(dynamic v) => (v as List? ?? const []).map((e) => e.toString()).toList();
double? _double(dynamic v) => v == null ? null : (v as num).toDouble();
int _int(dynamic v) => v == null ? 0 : (v as num).toInt();
DateTime _date(dynamic v) => DateTime.parse(v as String).toLocal();
DateTime? _dateOrNull(dynamic v) => v == null ? null : _date(v);

class User {
  User.fromJson(Json j)
      : id = j['id'],
        phone = j['phone'],
        email = j['email'],
        name = j['name'],
        city = j['city'],
        gender = j['gender'];

  final String id;
  final String phone;
  final String? email;
  final String? name;
  final String? city;
  final String? gender;

  String get firstName => (name ?? 'there').split(' ').first;
}

class ActiveSubscription {
  ActiveSubscription.fromJson(Json j)
      : id = j['id'],
        planId = j['planId'],
        planName = j['planName'],
        categories = _strings(j['categories']),
        startsAt = _date(j['startsAt']),
        endsAt = _date(j['endsAt']);

  final String id;
  final String planId;
  final String planName;
  final List<String> categories;
  final DateTime startsAt;
  final DateTime endsAt;

  int get daysLeft => endsAt.difference(DateTime.now()).inDays + 1;
}

class Plan {
  Plan.fromJson(Json j)
      : id = j['id'],
        code = j['code'],
        name = j['name'],
        description = j['description'],
        categories = _strings(j['categories']),
        pricePaise = _int(j['pricePaise']),
        durationDays = _int(j['durationDays']),
        features = _strings(j['features']),
        venueCount = _int(j['venueCount']);

  final String id;
  final String code;
  final String name;
  final String? description;
  final List<String> categories;
  final int pricePaise;
  final int durationDays;
  final List<String> features;
  final int venueCount;
}

class Subscription {
  Subscription.fromJson(Json j)
      : id = j['id'],
        planName = j['planName'],
        state = j['state'],
        startsAt = _date(j['startsAt']),
        endsAt = _date(j['endsAt']),
        amountPaise = _int(j['amountPaise']),
        categories = _strings(j['categories']);

  final String id;
  final String planName;
  final String state; // active | upcoming | expired | cancelled
  final DateTime startsAt;
  final DateTime endsAt;
  final int amountPaise;
  final List<String> categories;
}

class VenueSummary {
  VenueSummary.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        area = j['area'],
        city = j['city'],
        categories = _strings(j['categories']),
        opensAt = j['opensAt'],
        closesAt = j['closesAt'],
        trainerAvailable = j['trainerAvailable'] ?? false,
        amenities = _strings(j['amenities']),
        coverPhoto = j['coverPhoto'],
        distanceKm = _double(j['distanceKm']);

  final String id;
  final String name;
  final String? area;
  final String? city;
  final List<String> categories;
  final String? opensAt;
  final String? closesAt;
  final bool trainerAvailable;
  final List<String> amenities;
  final String? coverPhoto;
  final double? distanceKm;

  String get location => [area, city].whereType<String>().join(', ');
}

class Venue {
  Venue.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        description = j['description'],
        categories = _strings(j['categories']),
        address = j['address'],
        area = j['area'],
        city = j['city'],
        latitude = _double(j['latitude']),
        longitude = _double(j['longitude']),
        opensAt = j['opensAt'],
        closesAt = j['closesAt'],
        openDays = _strings(j['openDays']),
        contactPhone = j['contactPhone'],
        trainerAvailable = j['trainerAvailable'] ?? false,
        equipment = _strings(j['equipment']),
        amenities = _strings(j['amenities']),
        photos = _strings(j['photos']);

  final String id;
  final String name;
  final String? description;
  final List<String> categories;
  final String? address;
  final String? area;
  final String? city;
  final double? latitude;
  final double? longitude;
  final String? opensAt;
  final String? closesAt;
  final List<String> openDays;
  final String? contactPhone;
  final bool trainerAvailable;
  final List<String> equipment;
  final List<String> amenities;
  final List<String> photos;
}

class PlanRef {
  PlanRef.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        pricePaise = _int(j['pricePaise']),
        durationDays = _int(j['durationDays']);

  final String id;
  final String name;
  final int pricePaise;
  final int durationDays;
}

class Checkin {
  Checkin.fromJson(Json j)
      : id = j['id'],
        checkedInAt = _date(j['checkedInAt']),
        method = j['method'],
        venueName = j['venueName'] ?? (j['venue']?['name'] as String?) ?? '',
        venueArea = j['venueArea'] ?? (j['venue']?['area'] as String?),
        planName = j['planName'];

  final String id;
  final DateTime checkedInAt;
  final String method;
  final String venueName;
  final String? venueArea;
  final String? planName;
}

class VideoCategoryCount {
  VideoCategoryCount.fromJson(Json j)
      : id = j['id'],
        label = j['label'],
        count = _int(j['count']);

  final String id;
  final String label;
  final int count;
}

class Video {
  Video.fromJson(Json j)
      : id = j['id'],
        category = j['category'],
        title = j['title'],
        description = j['description'],
        trainerName = j['trainerName'],
        level = j['level'] ?? 'beginner',
        videoUrl = j['videoUrl'],
        thumbnailUrl = j['thumbnailUrl'],
        durationSeconds = j['durationSeconds'];

  final String id;
  final String category;
  final String title;
  final String? description;
  final String? trainerName;
  final String level;
  final String videoUrl;
  final String? thumbnailUrl;
  final int? durationSeconds;
}

class BuddyPost {
  BuddyPost.fromJson(Json j)
      : id = j['id'],
        venueId = j['venueId'],
        venueName = j['venueName'] ?? '',
        venueArea = j['venueArea'],
        slotDate = DateTime.parse(j['slotDate']),
        slotStart = j['slotStart'],
        slotEnd = j['slotEnd'],
        note = j['note'],
        matchCount = _int(j['matchCount']);

  final String id;
  final String venueId;
  final String venueName;
  final String? venueArea;
  final DateTime slotDate;
  final String slotStart;
  final String slotEnd;
  final String? note;
  final int matchCount;
}

class BuddyMatch {
  BuddyMatch.fromJson(Json j)
      : postId = j['postId'],
        slotStart = j['slotStart'],
        slotEnd = j['slotEnd'],
        note = j['note'],
        userId = j['userId'],
        name = j['name'],
        gender = j['gender'],
        requestId = j['requestId'],
        requestStatus = j['requestStatus'],
        requestDirection = j['requestDirection'];

  final String postId;
  final String slotStart;
  final String slotEnd;
  final String? note;
  final String userId;
  final String? name;
  final String? gender;
  final String? requestId;
  final String? requestStatus;
  final String? requestDirection;
}

class BuddyRequest {
  BuddyRequest.fromJson(Json j)
      : id = j['id'],
        status = j['status'],
        direction = j['direction'],
        otherUserId = j['otherUserId'],
        otherName = j['otherName'],
        venueName = j['venueName'] ?? '',
        slotDate = DateTime.parse(j['slotDate']),
        slotStart = j['slotStart'],
        slotEnd = j['slotEnd'],
        lastMessage = j['lastMessage'];

  final String id;
  final String status; // pending | accepted
  final String direction; // incoming | outgoing
  final String otherUserId;
  final String? otherName;
  final String venueName;
  final DateTime slotDate;
  final String slotStart;
  final String slotEnd;
  final String? lastMessage;
}

class ChatMessage {
  ChatMessage.fromJson(Json j)
      : id = j['id'],
        body = j['body'],
        createdAt = _date(j['createdAt']),
        rawCreatedAt = j['createdAt'],
        isMine = j['isMine'] == true;

  final String id;
  final String body;
  final DateTime createdAt;
  final String rawCreatedAt;
  final bool isMine;
}

class Contest {
  Contest.fromJson(Json j)
      : id = j['id'],
        title = j['title'],
        description = j['description'],
        period = j['period'],
        metric = j['metric'],
        startsOn = DateTime.parse(j['startsOn']),
        endsOn = DateTime.parse(j['endsOn']),
        reward = j['reward'],
        city = j['city'],
        participantCount = _int(j['participantCount']),
        joined = j['joined'] == true,
        unit = j['unit'] ?? '';

  final String id;
  final String title;
  final String? description;
  final String period;
  final String metric;
  final DateTime startsOn;
  final DateTime endsOn;
  final String? reward;
  final String? city;
  final int participantCount;
  final bool joined;
  final String unit;

  int get daysLeft => endsOn.difference(DateTime.now()).inDays + 1;
}

class LeaderEntry {
  LeaderEntry.fromJson(Json j)
      : userId = j['userId'],
        name = j['name'],
        city = j['city'],
        score = _double(j['score']) ?? 0,
        rank = _int(j['rank']);

  final String userId;
  final String? name;
  final String? city;
  final double score;
  final int rank;
}

class Leaderboard {
  Leaderboard.fromJson(Json j)
      : entries = (j['entries'] as List).map((e) => LeaderEntry.fromJson(e)).toList(),
        me = j['me'] == null ? null : LeaderEntry.fromJson(j['me']);

  final List<LeaderEntry> entries;
  final LeaderEntry? me;
}

class Activity {
  Activity.fromJson(Json j)
      : id = j['id'],
        type = j['type'],
        title = j['title'],
        durationMin = j['durationMin'],
        distanceKm = _double(j['distanceKm']),
        calories = j['calories'],
        loggedAt = _date(j['loggedAt']);

  final String id;
  final String type;
  final String? title;
  final int? durationMin;
  final double? distanceKm;
  final int? calories;
  final DateTime loggedAt;
}

class WeightPoint {
  WeightPoint.fromJson(Json j)
      : weightKg = _double(j['weightKg'])!,
        loggedOn = DateTime.parse(j['loggedOn']);

  final double weightKg;
  final DateTime loggedOn;
}

class HealthReport {
  HealthReport.fromJson(Json j)
      : days = _int(j['days']),
        totalCheckins = _int(j['attendance']['totalCheckins']),
        activeDays = _int(j['attendance']['activeDays']),
        uniqueVenues = _int(j['attendance']['uniqueVenues']),
        currentStreak = _int(j['attendance']['currentStreak']),
        checkinsPerDay = {
          for (final d in j['attendance']['perDay'] as List) DateTime.parse(d['date']): _int(d['count']),
        },
        topVenues = [
          for (final v in j['attendance']['topVenues'] as List) (name: v['name'] as String, visits: _int(v['visits'])),
        ],
        workoutCount = _int(j['workouts']['count']),
        totalMinutes = _int(j['workouts']['totalMinutes']),
        totalDistanceKm = _double(j['workouts']['totalDistanceKm']) ?? 0,
        totalCalories = _int(j['workouts']['totalCalories']),
        workoutsByType = [
          for (final t in j['workouts']['byType'] as List)
            (type: t['type'] as String, count: _int(t['count']), minutes: _int(t['minutes'])),
        ],
        latestWeight = j['weight']['latest'] == null ? null : WeightPoint.fromJson(j['weight']['latest']),
        weightChangeKg = _double(j['weight']['changeKg']),
        weightSeries = (j['weight']['series'] as List).map((w) => WeightPoint.fromJson(w)).toList();

  final int days;
  final int totalCheckins;
  final int activeDays;
  final int uniqueVenues;
  final int currentStreak;
  final Map<DateTime, int> checkinsPerDay;
  final List<({String name, int visits})> topVenues;
  final int workoutCount;
  final int totalMinutes;
  final double totalDistanceKm;
  final int totalCalories;
  final List<({String type, int count, int minutes})> workoutsByType;
  final WeightPoint? latestWeight;
  final double? weightChangeKg;
  final List<WeightPoint> weightSeries;
}

DateTime? parseDateOrNull(dynamic v) => _dateOrNull(v);
