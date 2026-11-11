// Address search / reverse geocoding via OpenStreetMap Nominatim (Partner BRD §3 step 3).
// Usage policy: ≤ 1 request / second (callers debounce), an identifying User-Agent, results cached by the caller.

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

const osmUserAgentPackage = 'com.fitkey.fitkey_partner';

class PlaceResult {
  PlaceResult({
    required this.lat,
    required this.lng,
    required this.displayName,
    this.area,
    this.city,
    this.road,
    this.postcode,
  });

  factory PlaceResult.fromJson(Map<String, dynamic> j) {
    final a = (j['address'] as Map?)?.cast<String, dynamic>() ?? const {};
    String? pick(List<String> keys) {
      for (final k in keys) {
        final v = a[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return null;
    }

    return PlaceResult(
      lat: double.tryParse('${j['lat']}') ?? 0,
      lng: double.tryParse('${j['lon']}') ?? 0,
      displayName: '${j['display_name'] ?? ''}',
      area: pick(['suburb', 'neighbourhood', 'quarter', 'city_district', 'residential', 'village', 'hamlet']),
      city: pick(['city', 'town', 'municipality', 'county', 'state_district']),
      road: pick(['road', 'pedestrian', 'street']),
      postcode: pick(['postcode']),
    );
  }

  final double lat;
  final double lng;
  final String displayName;
  final String? area;
  final String? city;
  final String? road;
  final String? postcode;

  /// First part of the display name ("Indiranagar") and the rest ("Bengaluru, Karnataka, 560038, India").
  String get title => displayName.split(',').first.trim();
  String get subtitle {
    final parts = displayName.split(',').map((s) => s.trim()).toList();
    return parts.length <= 1 ? '' : parts.skip(1).where((p) => p != 'India').join(', ');
  }
}

class PlaceSearch {
  PlaceSearch({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://nominatim.openstreetmap.org',
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              // Browsers forbid setting User-Agent (they send their own + Referer, which Nominatim accepts).
              headers: kIsWeb ? null : {'User-Agent': '$osmUserAgentPackage (FitKey Partner app)'},
            ));

  final Dio _dio;
  final _cache = <String, List<PlaceResult>>{};

  /// Free-text search limited to India.
  Future<List<PlaceResult>> search(String query) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    final key = q.toLowerCase();
    if (_cache[key] case final hit?) return hit;
    final r = await _dio.get<List<dynamic>>('/search', queryParameters: {
      'format': 'json',
      'countrycodes': 'in',
      'addressdetails': 1,
      'limit': 6,
      'q': q,
    });
    final out = [for (final j in r.data ?? const []) PlaceResult.fromJson((j as Map).cast<String, dynamic>())];
    _cache[key] = out;
    return out;
  }

  /// Address of a map pin (to fill area / city when blank).
  Future<PlaceResult?> reverse(double lat, double lng) async {
    final r = await _dio.get<Map<String, dynamic>>('/reverse', queryParameters: {
      'format': 'json',
      'addressdetails': 1,
      'zoom': 18,
      'lat': lat.toStringAsFixed(6),
      'lon': lng.toStringAsFixed(6),
    });
    final d = r.data;
    return d == null || d['error'] != null ? null : PlaceResult.fromJson(d);
  }
}
