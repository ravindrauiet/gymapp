import 'fitkey_api.dart';
import 'models.dart';

/// Averages are shown as "New" until a centre / trainer has this many ratings (BRD §8).
const kRatingsUntilAverage = 5;

/// Whether to show "New" instead of an average.
bool isNewRating(int? count) => (count ?? 0) < kRatingsUntilAverage;

/// Sub-rating keys → labels, per target type.
const kSubRatingLabels = <String, Map<String, String>>{
  'venue': {
    'cleanliness': 'Cleanliness',
    'equipment': 'Equipment',
    'staff': 'Staff',
    'crowd': 'Crowd',
    'value': 'Value for money',
  },
  'trainer': {
    'knowledge': 'Knowledge',
    'punctuality': 'Punctuality',
    'communication': 'Communication',
    'results': 'Results',
  },
};

class MyRating {
  MyRating.fromJson(Json j)
      : stars = (j['stars'] as num).toInt(),
        subRatings = {
          for (final e in (j['subRatings'] as Map? ?? const {}).entries) e.key.toString(): (e.value as num).toInt(),
        };

  final int stars;
  final Map<String, int> subRatings;
}

class RatingSummary {
  RatingSummary.fromJson(Json j)
      : targetType = j['targetType'],
        targetId = j['targetId'],
        avg = (j['avg'] as num?)?.toDouble(),
        count = (j['count'] as num? ?? 0).toInt(),
        distribution = {
          for (final e in (j['distribution'] as Map? ?? const {}).entries)
            int.parse(e.key.toString()): (e.value as num).toInt(),
        },
        subRatings = {
          for (final e in (j['subRatings'] as Map? ?? const {}).entries)
            e.key.toString(): ((e.value as Map)['avg'] as num).toDouble(),
        },
        myRating = j['myRating'] == null ? null : MyRating.fromJson(Map<String, dynamic>.from(j['myRating'])),
        canRate = j['canRate'] as bool?;

  final String targetType;
  final String targetId;
  final double? avg;
  final int count;
  final Map<int, int> distribution;

  /// Average per sub-rating key (only keys someone has rated).
  final Map<String, double> subRatings;
  final MyRating? myRating;

  /// null when signed out.
  final bool? canRate;

  bool get isNew => isNewRating(count);
}

/// An unrated centre visit / finished trainer session the member can rate now.
class PendingRating {
  PendingRating.fromJson(Json j)
      : targetType = j['targetType'],
        targetId = j['targetId'],
        sourceId = j['sourceId'],
        name = j['name'] ?? '',
        subtitle = j['subtitle'],
        photoUrl = j['photoUrl'],
        categories = (j['categories'] as List? ?? const []).map((e) => e.toString()).toList();

  final String targetType; // venue | trainer
  final String targetId;
  final String sourceId; // check-in or booking id
  final String name;
  final String? subtitle;
  final String? photoUrl;
  final List<String> categories;
}

class TrainerTypeInfo {
  TrainerTypeInfo.fromJson(Json j)
      : key = j['key'],
        label = j['label'],
        count = (j['count'] as num? ?? 0).toInt();

  final String key;
  final String label;
  final int count;
}

class TrainerCategoryGroup {
  TrainerCategoryGroup.fromJson(Json j)
      : key = j['key'],
        label = j['label'],
        count = (j['count'] as num? ?? 0).toInt(),
        types = (j['types'] as List).map((t) => TrainerTypeInfo.fromJson(t)).toList();

  final String key;
  final String label;
  final int count;
  final List<TrainerTypeInfo> types;
}

extension RatingsApi on FitkeyApi {
  /// Venue search with rating sort / filter. sort: relevance (default) | rating | distance.
  Future<List<VenueSummary>> venuesRanked({
    String? category,
    String? city,
    String? q,
    String? sort,
    double? minRating,
    int limit = 50,
    int page = 1,
  }) async {
    final r = await client.get('/venues', query: {
      'category': category,
      'city': city,
      'q': q,
      'sort': sort,
      'minRating': minRating,
      'limit': limit,
      'page': page,
    });
    return (r['venues'] as List).map((v) => VenueSummary.fromJson(v)).toList();
  }

  /// Trainers with category / rating filters. sort: relevance (default) | rating | price_low | price_high.
  Future<List<Trainer>> trainersFiltered({
    String? modes,
    String? group,
    String? type,
    String? q,
    String? sort,
    double? minRating,
  }) async {
    final r = await client.get('/trainers', query: {
      'modes': modes,
      'group': group,
      'type': type,
      'q': q,
      'sort': sort,
      'minRating': minRating,
    });
    return (r['trainers'] as List).map((t) => Trainer.fromJson(t)).toList();
  }

  /// Trainer groups / types that have at least one onboarded trainer.
  Future<List<TrainerCategoryGroup>> trainerCategories() async =>
      ((await client.get('/trainers/categories'))['groups'] as List)
          .map((g) => TrainerCategoryGroup.fromJson(g))
          .toList();

  Future<RatingSummary> ratingSummary(String targetType, String targetId) async =>
      RatingSummary.fromJson((await client.get('/ratings/$targetType/$targetId'))['summary']);

  Future<List<PendingRating>> pendingRatings() async =>
      ((await client.get('/ratings/pending'))['items'] as List).map((i) => PendingRating.fromJson(i)).toList();

  /// Creates or updates my rating. Returns the new (avg, count).
  Future<({double? avg, int count})> submitRating({
    required String targetType,
    required String targetId,
    required int stars,
    Map<String, int> subRatings = const {},
  }) async {
    final r = await client.post('/ratings', {
      'targetType': targetType,
      'targetId': targetId,
      'stars': stars,
      'subRatings': subRatings,
    });
    final s = r['summary'] as Map;
    return (avg: (s['avg'] as num?)?.toDouble(), count: (s['count'] as num).toInt());
  }

  /// "Not now" — remembered server-side for this visit.
  Future<void> dismissRating(PendingRating p) =>
      client.post('/ratings/dismiss', {'targetType': p.targetType, 'targetId': p.targetId, 'sourceId': p.sourceId});
}
