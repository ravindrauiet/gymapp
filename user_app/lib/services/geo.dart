import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Geometry for the Move tracker: distances, route simplification and the "area explored" grid.
class Geo {
  Geo._();

  static const _earth = 6371008.8;

  /// Great-circle distance in metres.
  static double distance(LatLng a, LatLng b) {
    final dLat = _rad(b.latitude - a.latitude);
    final dLng = _rad(b.longitude - a.longitude);
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(a.latitude)) * math.cos(_rad(b.latitude)) * math.pow(math.sin(dLng / 2), 2);
    return 2 * _earth * math.asin(math.min(1, math.sqrt(h)));
  }

  static double pathLength(List<LatLng> path) {
    var d = 0.0;
    for (var i = 1; i < path.length; i++) {
      d += distance(path[i - 1], path[i]);
    }
    return d;
  }

  static double _rad(double deg) => deg * math.pi / 180;

  // ------------------------------------------------------------------------------------- simplification

  /// Douglas–Peucker with a tolerance in metres (keeps the first and last point).
  static List<LatLng> simplify(List<LatLng> pts, {double toleranceM = 8}) {
    if (pts.length < 3) return List.of(pts);
    final lat0 = pts.first.latitude;
    final kx = 111320 * math.cos(_rad(lat0));
    const ky = 110540.0;
    final xy = [for (final p in pts) (p.longitude * kx, p.latitude * ky)];
    final keep = List<bool>.filled(pts.length, false)
      ..[0] = true
      ..[pts.length - 1] = true;
    final stack = <(int, int)>[(0, pts.length - 1)];
    while (stack.isNotEmpty) {
      final (s, e) = stack.removeLast();
      var maxD = 0.0;
      var idx = -1;
      for (var i = s + 1; i < e; i++) {
        final d = _segDist(xy[i], xy[s], xy[e]);
        if (d > maxD) {
          maxD = d;
          idx = i;
        }
      }
      if (idx != -1 && maxD > toleranceM) {
        keep[idx] = true;
        stack
          ..add((s, idx))
          ..add((idx, e));
      }
    }
    return [for (var i = 0; i < pts.length; i++) if (keep[i]) pts[i]];
  }

  static double _segDist((double, double) p, (double, double) a, (double, double) b) {
    final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : ((p.$1 - a.$1) * dx + (p.$2 - a.$2) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final x = a.$1 + t * dx - p.$1, y = a.$2 + t * dy - p.$2;
    return math.sqrt(x * x + y * y);
  }

  // ------------------------------------------------------------------------------------- explored grid

  /// Size of one explored cell (≈100 m × 100 m = 0.01 km²).
  static const cellDeg = 0.0009;
  static const cellAreaM2 = 10000.0;

  static double _lngStep(int row) => cellDeg / math.max(0.05, math.cos(_rad((row + 0.5) * cellDeg)));

  static (int, int) cellOf(LatLng p) {
    final row = (p.latitude / cellDeg).floor();
    return (row, (p.longitude / _lngStep(row)).floor());
  }

  /// Every ~100 m cell a route passed through (segments are walked in ~40 m steps, so fast travel leaves no gaps).
  static Set<(int, int)> cellsOf(List<LatLng> path) {
    final cells = <(int, int)>{};
    for (var i = 0; i < path.length; i++) {
      cells.add(cellOf(path[i]));
      if (i == 0) continue;
      final a = path[i - 1], b = path[i];
      final d = distance(a, b);
      if (d > 40 && d < 200000) {
        final n = (d / 40).ceil();
        for (var k = 1; k < n; k++) {
          final t = k / n;
          cells.add(cellOf(LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t)));
        }
      }
    }
    return cells;
  }

  static double areaOf(Set<(int, int)> cells) => cells.length * cellAreaM2;

  /// The four corners of a cell, for drawing it on the map.
  static List<LatLng> cellPolygon((int, int) c) {
    final (row, col) = c;
    final step = _lngStep(row);
    final s = row * cellDeg, n = (row + 1) * cellDeg, w = col * step, e = (col + 1) * step;
    return [LatLng(s, w), LatLng(s, e), LatLng(n, e), LatLng(n, w)];
  }

  // ------------------------------------------------------------------------------------- formatting

  static String km(double metres) =>
      metres < 1000 ? '${metres.round()} m' : '${(metres / 1000).toStringAsFixed(metres < 10000 ? 2 : 1)} km';

  static String area(double m2) {
    final km2 = m2 / 1e6;
    return km2 < 0.1 ? '${(m2 / 1e4).toStringAsFixed(1)} ha' : '${km2.toStringAsFixed(km2 < 10 ? 2 : 1)} km²';
  }

  static String duration(int s) {
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}m' : '$m:${sec.toString().padLeft(2, '0')}';
  }

  /// min/km for walk & run, km/h for rides and travel.
  static String pace(double metres, int seconds, {required bool asSpeed}) {
    if (metres < 20 || seconds <= 0) return '–';
    if (asSpeed) return '${(metres / seconds * 3.6).toStringAsFixed(1)} km/h';
    final secPerKm = seconds / (metres / 1000);
    return "${secPerKm ~/ 60}'${(secPerKm % 60).round().toString().padLeft(2, '0')}\" /km";
  }
}
