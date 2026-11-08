import 'package:latlong2/latlong.dart';

import 'fitkey_api.dart';
import 'models.dart';

// Move tracker + contacts matching. Backend: routes/activity.js.

double _d(Object? v) => v == null ? 0 : (v as num).toDouble();
int _i(Object? v) => v == null ? 0 : (v as num).toInt();

enum MoveMode {
  walk('Walk', 'walk'),
  run('Run', 'run'),
  cycle('Ride', 'cycle'),
  travel('Travel', 'travel');

  const MoveMode(this.label, this.api);
  final String label;
  final String api;

  static MoveMode parse(String? v) => MoveMode.values.firstWhere((m) => m.api == v, orElse: () => MoveMode.walk);

  /// Fastest believable speed (m/s) for this mode; faster GPS jumps are treated as glitches.
  double get maxSpeed => switch (this) { walk => 7, run => 11, cycle => 25, travel => 70 };

  /// Activity type for the Progress report (travel isn't exercise, so it isn't logged there).
  String? get activityType => switch (this) { walk => 'other', run => 'running', cycle => 'cycling', travel => null };
}

class MoveTrack {
  MoveTrack({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.mode,
    required this.distanceM,
    required this.durationS,
    required this.movingS,
    required this.steps,
    required this.areaM2,
    required this.maxSpeedMs,
    required this.path,
  });

  factory MoveTrack.fromJson(Json j) => MoveTrack(
        id: j['id'] as String,
        startedAt: DateTime.parse(j['startedAt'] as String).toLocal(),
        endedAt: DateTime.parse(j['endedAt'] as String).toLocal(),
        mode: MoveMode.parse(j['mode'] as String?),
        distanceM: _d(j['distanceM']),
        durationS: _i(j['durationS']),
        movingS: _i(j['movingS']),
        steps: _i(j['steps']),
        areaM2: _d(j['areaM2']),
        maxSpeedMs: j['maxSpeedMs'] == null ? null : _d(j['maxSpeedMs']),
        path: [
          for (final p in (j['path'] as List? ?? const []))
            LatLng(_d((p as List)[0]), _d(p[1])),
        ],
      );

  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final MoveMode mode;
  final double distanceM;
  final int durationS;
  final int movingS;
  final int steps;
  final double areaM2;
  final double? maxSpeedMs;
  final List<LatLng> path;
}

/// A contact who is already a FITKEY member.
class ContactMatch {
  ContactMatch.fromJson(Json j)
      : id = j['id'] as String,
        name = j['name'] as String?,
        avatarUrl = j['avatarUrl'] as String?,
        city = j['city'] as String?,
        hash = j['hash'] as String;

  final String id;
  final String? name;
  final String? avatarUrl;
  final String? city;
  final String hash;
}

extension ActivityApi on FitkeyApi {
  Future<MoveTrack> saveTrack(Json track) async =>
      MoveTrack.fromJson((await client.post('/activity/tracks', track))['track'] as Json);

  Future<List<MoveTrack>> tracks({int days = 30}) async =>
      ((await client.get('/activity/tracks', query: {'days': days}))['tracks'] as List)
          .map((t) => MoveTrack.fromJson(t as Json))
          .toList();

  Future<void> deleteTrack(String id) => client.delete('/activity/tracks/$id');

  Future<List<ContactMatch>> matchContacts(List<String> hashes) async =>
      ((await client.post('/activity/contacts/match', {'hashes': hashes}))['matches'] as List)
          .map((m) => ContactMatch.fromJson(m as Json))
          .toList();
}
