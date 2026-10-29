import 'fitkey_api.dart';
import 'models.dart';

class AppNotification {
  AppNotification.fromJson(Json j)
      : id = j['id'],
        type = j['type'],
        title = j['title'],
        body = j['body'],
        data = Map<String, dynamic>.from(j['data'] as Map? ?? const {}),
        read = j['readAt'] != null,
        createdAt = DateTime.parse(j['createdAt']).toLocal();

  final String id;

  /// e.g. feed_like, feed_comment, follow, coins, event, circle …
  final String type;
  final String title;
  final String? body;
  final Json data;
  final bool read;
  final DateTime createdAt;
}

extension NotificationsApi on FitkeyApi {
  Future<({List<AppNotification> items, int unread})> notifications({DateTime? before}) async {
    final r = await client.get('/notifications', query: {'before': before?.toUtc().toIso8601String()});
    return (
      items: (r['notifications'] as List).map((n) => AppNotification.fromJson(n)).toList(),
      unread: (r['unread'] as num).toInt(),
    );
  }

  Future<int> unreadNotifications() async => ((await client.get('/notifications/unread-count'))['unread'] as num).toInt();

  Future<void> markNotificationsRead([List<String>? ids]) => client.post('/notifications/read', {'ids': ?ids});
}
