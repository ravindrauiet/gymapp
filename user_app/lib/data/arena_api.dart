import 'fitkey_api.dart';
import 'models.dart';

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
int? _intOrNull(Object? v) => (v as num?)?.toInt();

// ProveIt (formerly "ProveIt") — endpoints under /api/v1/arena.

/// A badge earned for completing a level the first time.
class ArenaBadgeInfo {
  ArenaBadgeInfo.fromJson(Json j)
      : earnedAt = j['earnedAt'] == null ? null : DateTime.parse(j['earnedAt']).toLocal(),
        coins = _int(j['coins']),
        coinsStatus = j['coinsStatus'] ?? 'none';

  final DateTime? earnedAt;
  final int coins;

  /// credited | pending (added once the wallet confirms) | none
  final String coinsStatus;
}

/// One level of a ProveIt challenge, e.g. level 2 = 50 reps → 25 points + 25 coins on first completion.
class ArenaLevel {
  ArenaLevel.fromJson(Json j)
      : level = _int(j['level']),
        target = _int(j['target']),
        points = _int(j['points']),
        coins = _int(j['coins']),
        badge = j['badge'] == null ? null : ArenaBadgeInfo.fromJson(j['badge']);

  /// 1, 2, 3
  final int level;

  /// Reps (seconds for plank) needed to complete the level.
  final int target;
  final int points;

  /// ProveIt coins for the first completion.
  final int coins;

  /// Set once this level was completed.
  final ArenaBadgeInfo? badge;
}

/// My standing on one exercise.
class ArenaStats {
  ArenaStats.fromJson(Json j)
      : participants = _int(j['participants']),
        top10Threshold = _intOrNull(j['top10Threshold']),
        myBest = _intOrNull(j['myBest']),
        myRank = _intOrNull(j['myRank']),
        myCityRank = _intOrNull(j['myCityRank']),
        myCity = j['myCity'],
        cityParticipants = _int(j['cityParticipants']),
        levelsBest = _intOrNull(j['levelsBest']),
        myWeekTotal = _int(j['myWeekTotal']),
        pointsToday = _int(j['pointsToday']),
        myAttempts = _int(j['myAttempts']);

  /// Members with at least one set on the all-India board.
  final int participants;

  /// Score of the #10 member — null while fewer than 10 members have a set (any set enters the top 10).
  final int? top10Threshold;
  /// Best Unlimited single set — the score behind the All India Rank.
  final int? myBest;

  /// All India Rank (AIR), null until an Unlimited set is saved.
  final int? myRank;
  final int? myCityRank;
  final String? myCity;
  final int cityParticipants;

  /// Best Levels-mode set (does not rank).
  final int? levelsBest;
  final int myWeekTotal;
  final int pointsToday;
  final int myAttempts;
}

class ArenaExercise {
  ArenaExercise.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        unit = j['unit'],
        levels = (j['levels'] as List).map((l) => ArenaLevel.fromJson(l)).toList(),
        dailyPointsCap = _int(j['dailyPointsCap']),
        tagline = j['tagline'],
        howTo = List<String>.from(j['howTo'] as List? ?? const []),
        tips = List<String>.from(j['tips'] as List? ?? const []),
        stats = ArenaStats.fromJson(j['stats'] as Json);

  /// pushups | pullups | squats | plank (v1 scope)
  final String id;
  final String name;

  /// 'reps' or 'seconds' (plank).
  final String unit;
  final List<ArenaLevel> levels;
  final int dailyPointsCap;
  final String? tagline;
  final List<String> howTo;
  final List<String> tips;
  final ArenaStats stats;

  bool get timed => unit == 'seconds';

  /// "50 reps" / "60 s".
  String format(int value) => timed ? '$value s' : '$value ${value == 1 ? 'rep' : 'reps'}';
}

class ArenaBoardEntry {
  ArenaBoardEntry.fromJson(Json j)
      : userId = j['userId'],
        name = j['name'],
        city = j['city'],
        avatarUrl = j['avatarUrl'],
        score = _int(j['score']),
        rank = _int(j['rank']),
        indiaRank = _intOrNull(j['indiaRank']),
        sets = _intOrNull(j['sets']),
        clipUrl = j['clipUrl'];

  final String userId;
  final String? name;
  final String? city;
  final String? avatarUrl;

  /// Best single set (best board) or weekly total (weekly board).
  final int score;
  final int rank;
  final int? indiaRank;
  final int? sets;

  /// Proof clip — only on all-India top-10 best sets.
  final String? clipUrl;
}

class ArenaBoard {
  ArenaBoard.fromJson(Json j)
      : board = j['board'],
        city = j['city'],
        entries = (j['entries'] as List).map((e) => ArenaBoardEntry.fromJson(e)).toList(),
        me = j['me'] == null ? null : ArenaBoardEntry.fromJson(j['me']),
        total = _int(j['total']);

  /// 'best' or 'weekly'.
  final String board;
  final String? city;
  final List<ArenaBoardEntry> entries;
  final ArenaBoardEntry? me;
  final int total;
}

class ArenaAttempt {
  ArenaAttempt.fromJson(Json j)
      : id = j['id'],
        exerciseId = j['exerciseId'],
        mode = j['mode'] ?? 'levels',
        level = _intOrNull(j['level']),
        reps = _int(j['reps']),
        completed = j['completed'] == true,
        points = _int(j['points']),
        durationSec = _intOrNull(j['durationSec']),
        partialReps = _int(j['partialReps']),
        clipUrl = j['clipUrl'],
        clipStatus = j['clipStatus'] ?? 'none',
        createdAt = DateTime.parse(j['createdAt']).toLocal();

  final String id;
  final String exerciseId;

  /// levels | unlimited
  final String mode;
  final int? level;
  final int reps;
  final bool completed;
  final int points;
  final int? durationSec;
  final int partialReps;
  final String? clipUrl;

  /// none | pending | uploaded | unavailable
  final String clipStatus;
  final DateTime createdAt;
}

class ArenaSubmitResult {
  ArenaSubmitResult.fromJson(Json j)
      : attempt = ArenaAttempt.fromJson(j['attempt']),
        pointsAwarded = _int(j['pointsAwarded']),
        levelPoints = _int(j['levelPoints']),
        badgeLevel = j['badge'] == null ? null : _int(j['badge']['level']),
        badgeCoins = j['badge'] == null ? 0 : _int(j['badge']['coins']),
        badgeCoinsStatus = j['badge']?['coinsStatus'],
        myRank = _intOrNull(j['myRank']),
        myCityRank = _intOrNull(j['myCityRank']),
        myCity = j['myCity'],
        dailyCapReached = j['dailyCapReached'] == true,
        rank = _intOrNull(j['rank']),
        previousBest = _intOrNull(j['previousBest']),
        personalBest = j['personalBest'] == true,
        qualifiesTop10 = j['qualifiesTop10'] == true,
        clipRequired = j['clipRequired'] == true;

  final ArenaAttempt attempt;
  final int pointsAwarded;

  /// Points of the highest level the set reached (before the daily cap).
  final int levelPoints;
  final bool dailyCapReached;

  /// New badge from this set (Levels mode), its coins and whether they are already in the wallet.
  final int? badgeLevel;
  final int badgeCoins;
  final String? badgeCoinsStatus;

  /// My AIR / city rank after this Unlimited set.
  final int? myRank;
  final int? myCityRank;
  final String? myCity;

  /// AIR of this set — null when it did not beat my previous best (or a Levels set).
  final int? rank;
  final int? previousBest;
  final bool personalBest;
  final bool qualifiesTop10;
  final bool clipRequired;
}

extension ArenaApi on FitkeyApi {
  Future<List<ArenaExercise>> arenaExercises() async =>
      ((await client.get('/arena/exercises'))['exercises'] as List).map((e) => ArenaExercise.fromJson(e)).toList();

  Future<ArenaExercise> arenaExercise(String id) async =>
      ArenaExercise.fromJson((await client.get('/arena/exercises/$id'))['exercise']);

  /// [board] is 'best' (max single set) or 'weekly' (total this week). [city] null = All India.
  Future<ArenaBoard> arenaLeaderboard(String exerciseId, {String board = 'best', String? city}) async =>
      ArenaBoard.fromJson(await client.get('/arena/exercises/$exerciseId/leaderboard', query: {'board': board, 'city': city}));

  Future<({bool qualifies, int rank})> arenaQualifies(String exerciseId, int reps) async {
    final r = await client.get('/arena/exercises/$exerciseId/qualifies', query: {'reps': reps});
    return (qualifies: r['qualifies'] == true, rank: _int(r['rank']));
  }

  /// Unlimited sets have no [level]; Levels sets need one.
  Future<ArenaSubmitResult> submitArenaAttempt({
    required String exerciseId,
    required bool unlimited,
    int? level,
    required int reps,
    required int durationSec,
    int partialReps = 0,
  }) async =>
      ArenaSubmitResult.fromJson(await client.post('/arena/attempts', {
        'exerciseId': exerciseId,
        'mode': unlimited ? 'unlimited' : 'levels',
        'level': unlimited ? null : level,
        'reps': reps,
        'durationSec': durationSec,
        'partialReps': partialReps,
      }));

  /// Attaches an uploaded proof clip (url from [FitkeyApi.upload]) or, with [clipUrl] null, reports that the
  /// device could not record one.
  Future<ArenaAttempt> attachArenaClip(String attemptId, String? clipUrl) async => ArenaAttempt.fromJson(
      (await client.post('/arena/attempts/$attemptId/clip', clipUrl == null ? {'unavailable': true} : {'clipUrl': clipUrl}))['attempt']);

  Future<List<ArenaAttempt>> myArenaAttempts({String? exerciseId, int limit = 30}) async =>
      ((await client.get('/arena/attempts/me', query: {'exerciseId': exerciseId, 'limit': limit}))['attempts'] as List)
          .map((a) => ArenaAttempt.fromJson(a))
          .toList();

  /// Cities on the AIR board of [exerciseId], most members first.
  Future<List<({String city, int members})>> arenaCities(String exerciseId) async =>
      ((await client.get('/arena/exercises/$exerciseId/cities'))['cities'] as List)
          .map((c) => (city: c['city'] as String, members: _int(c['members'])))
          .toList();

  Future<ProveItSummary> proveItSummary() async => ProveItSummary.fromJson(await client.get('/arena/me'));
}

class ProveItBadge {
  ProveItBadge.fromJson(Json j)
      : exerciseId = j['exerciseId'],
        name = j['name'],
        unit = j['unit'],
        level = _int(j['level']),
        target = _int(j['target']),
        coins = _int(j['coins']),
        coinsStatus = j['coinsStatus'] ?? 'none',
        earnedAt = DateTime.parse(j['earnedAt']).toLocal();

  final String exerciseId;
  final String name;
  final String unit;
  final int level;
  final int target;
  final int coins;
  final String coinsStatus;
  final DateTime earnedAt;

  String get targetLabel => unit == 'seconds' ? '$target s' : '$target reps';
}

class ProveItRank {
  ProveItRank.fromJson(Json j)
      : exerciseId = j['exerciseId'],
        name = j['name'],
        unit = j['unit'],
        best = _intOrNull(j['best']),
        rank = _intOrNull(j['rank']),
        cityRank = _intOrNull(j['cityRank']),
        city = j['city'],
        participants = _int(j['participants']);

  final String exerciseId;
  final String name;
  final String unit;
  final int? best;
  final int? rank;
  final int? cityRank;
  final String? city;
  final int participants;
}

/// GET /arena/me — badges, ProveIt coins and AIR per challenge.
class ProveItSummary {
  ProveItSummary.fromJson(Json j)
      : badges = (j['badges'] as List).map((b) => ProveItBadge.fromJson(b)).toList(),
        coinsEarned = _int(j['coinsEarned']),
        coinsPending = _int(j['coinsPending']),
        badgesTotal = _int(j['badgesTotal']),
        ranks = (j['ranks'] as List).map((r) => ProveItRank.fromJson(r)).toList();

  final List<ProveItBadge> badges;
  final int coinsEarned;
  final int coinsPending;
  final int badgesTotal;
  final List<ProveItRank> ranks;

  /// Best (lowest) AIR across challenges.
  ProveItRank? get bestRank {
    final ranked = ranks.where((r) => r.rank != null).toList()..sort((a, b) => a.rank!.compareTo(b.rank!));
    return ranked.isEmpty ? null : ranked.first;
  }
}
