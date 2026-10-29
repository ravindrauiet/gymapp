import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ui/ui.dart';
import 'fitkey_api.dart';
import 'models.dart';

// ---------------------------------------------------------------------------
// Studio categories (BRD §7)
// ---------------------------------------------------------------------------

class StudioType {
  StudioType.fromJson(Json j)
      : key = j['key'],
        label = j['label'],
        count = (j['count'] as num?)?.toInt() ?? 0;

  final String key;
  final String label;
  final int count;
}

/// Filter values that actually exist inside a group (so we never offer a filter that returns nothing).
class StudioFilters {
  StudioFilters.fromJson(Json j)
      : levels = _strings(j['levels']),
        durations = _strings(j['durations']),
        equipment = _strings(j['equipment']),
        trainers = _strings(j['trainers']);

  final List<String> levels;

  /// Duration buckets: '10' (≤15 min), '20' (16–25 min), '30' (25+ min).
  final List<String> durations;

  /// none | dumbbells | gym
  final List<String> equipment;
  final List<String> trainers;
}

/// A Studio category group (Home Workouts, Gym Workouts…) — only non-empty ones come from the server.
class StudioGroup {
  StudioGroup.fromJson(Json j)
      : key = j['key'],
        label = j['label'],
        count = (j['count'] as num?)?.toInt() ?? 0,
        types = ((j['types'] as List?) ?? const []).map((t) => StudioType.fromJson(t)).toList(),
        filters = StudioFilters.fromJson(Map<String, dynamic>.from(j['filters'] as Map? ?? const {}));

  final String key;
  final String label;
  final int count;
  final List<StudioType> types;
  final StudioFilters filters;

  CatVisual get visual => studioGroupVisual(key, label);
}

List<String> _strings(Object? v) => ((v as List?) ?? const []).map((e) => '$e').toList();

const _groupVisuals = <String, (IconData, Color, Color, String)>{
  'home': (Icons.home_rounded, AppColors.teal, AppColors.tealSoft, AppImages.homeWorkout),
  'gym': (Icons.fitness_center_rounded, AppColors.primary, AppColors.primarySoft, AppImages.strength),
  'goal': (Icons.flag_rounded, AppColors.amber, AppColors.amberSoft, AppImages.running),
  'yoga_mind': (Icons.self_improvement_rounded, AppColors.purple, AppColors.purpleSoft, AppImages.yoga),
  'dance_cardio': (Icons.music_note_rounded, AppColors.pink, AppColors.pinkSoft, AppImages.dance),
  'martial_arts': (Icons.sports_mma_rounded, AppColors.red, AppColors.redSoft, AppImages.martialArts),
  'body_part': (Icons.accessibility_new_rounded, AppColors.blue, AppColors.blueSoft, AppImages.gymFloor),
  'recovery': (Icons.spa_rounded, AppColors.green, AppColors.greenSoft, AppImages.groupClass),
  'special': (Icons.diversity_1_rounded, AppColors.purple, AppColors.purpleSoft, AppImages.onboarding),
  'learn': (Icons.menu_book_rounded, AppColors.teal, AppColors.tealSoft, AppImages.foodBowl),
};

/// Icon, colour and photo for a Studio group key.
CatVisual studioGroupVisual(String key, [String? label]) {
  final v = _groupVisuals[key];
  if (v == null) return videoVisual(key);
  return CatVisual(label ?? key, v.$1, v.$2, v.$3, v.$4);
}

/// Visual for a video: its Studio group when tagged, else the legacy category.
CatVisual studioVideoVisual(Video v) =>
    v.groupKey != null ? studioGroupVisual(v.groupKey!, v.groupLabel) : videoVisual(v.category);

String studioLevelLabel(String level) => level.isEmpty ? level : level[0].toUpperCase() + level.substring(1);

String studioDurationLabel(String bucket) => switch (bucket) {
      '10' => '10 min',
      '20' => '20 min',
      '30' => '30+ min',
      _ => bucket,
    };

String studioEquipmentLabel(String e) => switch (e) {
      'none' => 'No equipment',
      'dumbbells' => 'Dumbbells',
      'gym' => 'Gym',
      _ => e,
    };

extension StudioApi on FitkeyApi {
  /// Non-empty Studio groups with their non-empty types and available filters.
  Future<List<StudioGroup>> studioGroups() async =>
      ((await client.get('/videos/groups'))['groups'] as List).map((g) => StudioGroup.fromJson(g)).toList();

  /// Server-side Studio search / filtering. Every parameter is optional.
  Future<List<Video>> studioVideos({
    String? q,
    String? group,
    String? type,
    String? level,
    String? duration,
    String? equipment,
    String? trainer,
    int limit = 50,
    int page = 1,
  }) async {
    final r = await client.get('/videos', query: {
      'q': q,
      'group': group,
      'type': type,
      'level': level,
      'duration': duration,
      'equipment': equipment,
      'trainer': trainer,
      'limit': limit,
      'page': page,
    });
    return (r['videos'] as List).map((v) => Video.fromJson(v)).toList();
  }

  // ---- HealthStop search (BRD §5) -------------------------------------------
  Future<List<HealthChemist>> searchHealthChemists({String? city, String? q}) async {
    final r = await client.get('/healthstop/chemists', query: {'city': city, 'q': q});
    return (r['chemists'] as List).map((c) => HealthChemist.fromJson(c)).toList();
  }

  Future<List<HealthClinic>> searchHealthClinics({String? city, String? q}) async {
    final r = await client.get('/healthstop/clinics', query: {'city': city, 'q': q});
    return (r['clinics'] as List).map((c) => HealthClinic.fromJson(c)).toList();
  }
}

// ---------------------------------------------------------------------------
// Recent searches — kept on the device (flutter_secure_storage), newest first.
// ---------------------------------------------------------------------------

class RecentSearches {
  const RecentSearches(this.key, {this.max = 8});

  final String key;
  final int max;

  static const _storage = FlutterSecureStorage();

  Future<List<String>> load() async {
    try {
      final raw = await _storage.read(key: key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List).map((e) => '$e').toList();
    } catch (_) {
      return [];
    }
  }

  /// Adds [query] to the top (case-insensitive de-dupe) and returns the new list.
  Future<List<String>> add(String query) async {
    final q = query.trim();
    final list = await load();
    if (q.length < 2) return list;
    list
      ..removeWhere((e) => e.toLowerCase() == q.toLowerCase())
      ..insert(0, q);
    final next = list.take(max).toList();
    await _save(next);
    return next;
  }

  Future<List<String>> remove(String query) async {
    final list = (await load())..remove(query);
    await _save(list);
    return list;
  }

  Future<void> clear() => _save(const []);

  Future<void> _save(List<String> list) async {
    try {
      await _storage.write(key: key, value: jsonEncode(list));
    } catch (_) {/* storage unavailable — recents are a convenience only */}
  }
}
