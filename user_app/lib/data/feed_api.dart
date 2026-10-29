import 'package:fitkey_core/fitkey_core.dart' show AppConfig;

import 'fitkey_api.dart';
import 'models.dart';

// FitFeed (BRD §1): models + endpoints under /api/v1/feed.

int _n(dynamic v) => v == null ? 0 : (v as num).toInt();
double? _d(dynamic v) => v == null ? null : (v as num).toDouble();
DateTime? _t(dynamic v) => v == null ? null : DateTime.parse(v as String).toLocal();

/// Post categories (server ids → labels).
const feedCategories = <String, String>{
  'gym': 'Gym',
  'yoga': 'Yoga',
  'nutrition': 'Nutrition',
  'weight_loss': 'Weight Loss',
  'weight_gain': 'Weight Gain',
  'mental_wellness': 'Mental Wellness',
  'sports': 'Sports',
};

enum FeedTab {
  forYou('foryou', 'For You'),
  following('following', 'Following'),
  journeys('journeys', 'Journeys'),
  experts('experts', 'Expert Blogs');

  const FeedTab(this.id, this.label);
  final String id;
  final String label;
}

/// `trainer` | `nutritionist` | `journey` | null
typedef FeedBadge = String?;

class FeedAuthor {
  FeedAuthor.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        avatarUrl = j['avatarUrl'],
        city = j['city'],
        badge = j['badge'],
        trainerId = j['trainerId'],
        following = j['following'] == true;

  final String id;
  final String? name;
  final String? avatarUrl;
  final String? city;
  final FeedBadge badge;
  final String? trainerId;
  bool following;

  String get displayName => (name == null || name!.trim().isEmpty) ? 'FITKEY member' : name!;
}

class JourneyStats {
  JourneyStats({this.weightKg, this.bodyFatPct, this.waistCm, this.calories, this.proteinG, this.date});
  JourneyStats.fromJson(Json? j)
      : weightKg = _d(j?['weightKg']),
        bodyFatPct = _d(j?['bodyFatPct']),
        waistCm = _d(j?['waistCm']),
        calories = j?['calories'] == null ? null : _n(j?['calories']),
        proteinG = _d(j?['proteinG']),
        date = j?['date'];

  double? weightKg;
  double? bodyFatPct;
  double? waistCm;
  int? calories;
  double? proteinG;
  String? date; // YYYY-MM-DD

  bool get isEmpty => weightKg == null && bodyFatPct == null && waistCm == null && calories == null && proteinG == null;

  Json toJson() => {
        'weightKg': ?weightKg,
        'bodyFatPct': ?bodyFatPct,
        'waistCm': ?waistCm,
        'calories': ?calories,
        'proteinG': ?proteinG,
        'date': ?date,
      };
}

class JourneyData {
  JourneyData({this.goal = 'fitness', this.beforeUrl, this.afterUrl, JourneyStats? start, JourneyStats? current})
      : start = start ?? JourneyStats(),
        current = current ?? JourneyStats();
  JourneyData.fromJson(Json j)
      : goal = j['goal'] ?? 'fitness',
        beforeUrl = j['beforeUrl'],
        afterUrl = j['afterUrl'],
        start = JourneyStats.fromJson(j['start'] as Json?),
        current = JourneyStats.fromJson(j['current'] as Json?);

  String goal; // weight_loss | weight_gain | fitness
  String? beforeUrl;
  String? afterUrl;
  JourneyStats start;
  JourneyStats current;

  String get goalLabel => switch (goal) {
        'weight_loss' => 'Weight loss',
        'weight_gain' => 'Weight gain',
        _ => 'Fitness',
      };

  double? get weightChange =>
      start.weightKg != null && current.weightKg != null ? current.weightKg! - start.weightKg! : null;

  Json toJson() => {
        'goal': goal,
        'beforeUrl': ?beforeUrl,
        'afterUrl': ?afterUrl,
        'start': start.toJson(),
        'current': current.toJson(),
      };
}

class JourneyUpdate {
  JourneyUpdate.fromJson(Json j)
      : id = j['id'],
        note = j['note'],
        photoUrl = j['photoUrl'],
        weightKg = _d(j['weightKg']),
        createdAt = _t(j['createdAt'])!;

  final String id;
  final String? note;
  final String? photoUrl;
  final double? weightKg;
  final DateTime createdAt;
}

class FeedPost {
  FeedPost.fromJson(Json j)
      : id = j['id'],
        kind = j['kind'],
        status = j['status'],
        visibility = j['visibility'],
        category = j['category'],
        caption = j['caption'],
        title = j['title'],
        coverUrl = j['coverUrl'],
        body = j['body'],
        excerpt = j['excerpt'],
        readMinutes = j['readMinutes'] == null ? null : _n(j['readMinutes']),
        images = List<String>.from(j['images'] as List? ?? const []),
        journey = j['journey'] == null ? null : JourneyData.fromJson(Map<String, dynamic>.from(j['journey'] as Map)),
        facesBlurred = j['facesBlurred'] == true,
        likeCount = _n(j['likeCount']),
        commentCount = _n(j['commentCount']),
        saveCount = _n(j['saveCount']),
        shareCount = _n(j['shareCount']),
        liked = j['liked'] == true,
        saved = j['saved'] == true,
        isMine = j['isMine'] == true,
        publishedAt = _t(j['publishedAt']),
        createdAt = _t(j['createdAt'])!,
        author = FeedAuthor.fromJson(j['author']),
        updates = j['updates'] == null
            ? null
            : (j['updates'] as List).map((u) => JourneyUpdate.fromJson(u)).toList();

  final String id;
  final String kind; // photo | blog | journey
  final String status; // draft | published
  final String visibility; // public | followers
  final String? category;
  final String? caption;
  final String? title;
  final String? coverUrl;
  final String? body;
  final String? excerpt;
  final int? readMinutes;
  final List<String> images;
  final JourneyData? journey;
  final bool facesBlurred;
  int likeCount;
  int commentCount;
  int saveCount;
  int shareCount;
  bool liked;
  bool saved;
  final bool isMine;
  final DateTime? publishedAt;
  final DateTime createdAt;
  final FeedAuthor author;
  final List<JourneyUpdate>? updates;

  bool get isDraft => status == 'draft';
  DateTime get time => publishedAt ?? createdAt;

  /// The link shared to WhatsApp / Instagram / anywhere (a public preview page served by the API).
  String get shareUrl => '${AppConfig.apiUrl}/feed/share/$id';

  /// Best image to represent the post (cards, grids, share previews).
  String? get thumbnail => coverUrl ?? (images.isNotEmpty ? images.first : null) ?? journey?.afterUrl;
}

class FeedComment {
  FeedComment.fromJson(Json j)
      : id = j['id'],
        body = j['body'],
        createdAt = _t(j['createdAt'])!,
        userId = j['user']['id'],
        userName = j['user']['name'],
        userAvatarUrl = j['user']['avatarUrl'],
        userBadge = j['user']['badge'],
        isMine = j['isMine'] == true,
        canDelete = j['canDelete'] == true;

  final String id;
  final String body;
  final DateTime createdAt;
  final String userId;
  final String? userName;
  final String? userAvatarUrl;
  final FeedBadge userBadge;
  final bool isMine;
  final bool canDelete;
}

class FeedPerson {
  FeedPerson.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        avatarUrl = j['avatarUrl'],
        city = j['city'],
        badge = j['badge'],
        followers = j['followers'] == null ? null : _n(j['followers']),
        postCount = j['postCount'] == null ? null : _n(j['postCount']),
        following = j['following'] == true,
        isMe = j['isMe'] == true;

  final String id;
  final String? name;
  final String? avatarUrl;
  final String? city;
  final FeedBadge badge;
  final int? followers;
  final int? postCount;
  bool following;
  final bool isMe;

  String get displayName => (name == null || name!.trim().isEmpty) ? 'FITKEY member' : name!;
}

class FeedProfile {
  FeedProfile.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        avatarUrl = j['avatarUrl'],
        city = j['city'],
        bio = j['bio'],
        badge = j['badge'],
        trainerId = j['trainerId'],
        followers = _n(j['followers']),
        following = _n(j['following']),
        postCount = _n(j['postCount']),
        journeyCount = _n(j['journeyCount']),
        isFollowing = j['isFollowing'] == true,
        followsMe = j['followsMe'] == true,
        isMe = j['isMe'] == true;

  final String id;
  final String? name;
  final String? avatarUrl;
  final String? city;
  final String? bio;
  final FeedBadge badge;
  final String? trainerId;
  int followers;
  final int following;
  final int postCount;
  final int journeyCount;
  bool isFollowing;
  final bool followsMe;
  final bool isMe;

  String get displayName => (name == null || name!.trim().isEmpty) ? 'FITKEY member' : name!;
}

typedef FeedPage = ({List<FeedPost> posts, String? nextCursor});

extension FeedApi on FitkeyApi {
  FeedPage _page(Json r) => (
        posts: (r['posts'] as List).map((p) => FeedPost.fromJson(p)).toList(),
        nextCursor: r['nextCursor'] as String?,
      );

  Future<FeedPage> feed({FeedTab tab = FeedTab.forYou, String? category, String? cursor}) async =>
      _page(await client.get('/feed', query: {'tab': tab.id, 'category': category, 'cursor': cursor}));

  Future<FeedPage> savedPosts({String? cursor}) async => _page(await client.get('/feed/saved', query: {'cursor': cursor}));

  Future<List<FeedPost>> feedDrafts() async => _page(await client.get('/feed/drafts')).posts;

  Future<FeedPost> feedPost(String id) async => FeedPost.fromJson((await client.get('/feed/posts/$id'))['post']);

  Future<FeedPost> createFeedPost(Json fields) async => FeedPost.fromJson((await client.post('/feed/posts', fields))['post']);

  Future<FeedPost> updateFeedPost(String id, Json fields) async =>
      FeedPost.fromJson((await client.patch('/feed/posts/$id', fields))['post']);

  Future<void> deleteFeedPost(String id) => client.delete('/feed/posts/$id');

  Future<void> addJourneyUpdate(String postId, {String? note, String? photoUrl, double? weightKg}) =>
      client.post('/feed/posts/$postId/updates', {'note': ?note, 'photoUrl': ?photoUrl, 'weightKg': ?weightKg});

  Future<void> deleteJourneyUpdate(String postId, String updateId) => client.delete('/feed/posts/$postId/updates/$updateId');

  Future<({bool liked, int likeCount})> setLike(String postId, bool like) async {
    final r = like ? await client.post('/feed/posts/$postId/like') : await client.delete('/feed/posts/$postId/like');
    return (liked: r['liked'] == true, likeCount: _n(r['likeCount']));
  }

  Future<({bool saved, int saveCount})> setSave(String postId, bool save) async {
    final r = save ? await client.post('/feed/posts/$postId/save') : await client.delete('/feed/posts/$postId/save');
    return (saved: r['saved'] == true, saveCount: _n(r['saveCount']));
  }

  Future<({int shareCount, int sentTo})> recordShare(String postId, {List<String> toUserIds = const []}) async {
    final r = await client.post('/feed/posts/$postId/share', {'toUserIds': toUserIds});
    return (shareCount: _n(r['shareCount']), sentTo: _n(r['sentTo']));
  }

  Future<void> reportFeedPost(String postId, String reason) => client.post('/feed/posts/$postId/report', {'reason': reason});

  Future<({List<FeedComment> comments, String? nextCursor})> feedComments(String postId, {String? cursor}) async {
    final r = await client.get('/feed/posts/$postId/comments', query: {'cursor': cursor});
    return (
      comments: (r['comments'] as List).map((c) => FeedComment.fromJson(c)).toList(),
      nextCursor: r['nextCursor'] as String?,
    );
  }

  Future<FeedComment> addFeedComment(String postId, String body) async =>
      FeedComment.fromJson((await client.post('/feed/posts/$postId/comments', {'body': body}))['comment']);

  Future<void> deleteFeedComment(String id) => client.delete('/feed/comments/$id');

  Future<FeedProfile> feedProfile(String userId) async => FeedProfile.fromJson((await client.get('/feed/users/$userId'))['profile']);

  Future<FeedProfile> myFeedProfile() async => FeedProfile.fromJson((await client.get('/feed/me'))['profile']);

  Future<FeedProfile> updateFeedBio(String? bio) async => FeedProfile.fromJson((await client.patch('/feed/me', {'bio': bio}))['profile']);

  Future<FeedPage> userFeedPosts(String userId, {String? kind, String? cursor}) async =>
      _page(await client.get('/feed/users/$userId/posts', query: {'kind': kind, 'cursor': cursor}));

  Future<({bool following, int followers})> setFollow(String userId, bool follow) async {
    final r = follow ? await client.post('/feed/users/$userId/follow') : await client.delete('/feed/users/$userId/follow');
    return (following: r['following'] == true, followers: _n(r['followers']));
  }

  Future<({List<FeedPerson> users, String? nextCursor})> followList(String userId, {required bool followers, String? cursor}) async {
    final r = await client.get('/feed/users/$userId/${followers ? 'followers' : 'following'}', query: {'cursor': cursor});
    return (
      users: (r['users'] as List).map((u) => FeedPerson.fromJson(u)).toList(),
      nextCursor: r['nextCursor'] as String?,
    );
  }

  Future<List<FeedPerson>> feedSuggestions() async =>
      ((await client.get('/feed/suggestions'))['users'] as List).map((u) => FeedPerson.fromJson(u)).toList();
}
