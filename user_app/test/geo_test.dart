import 'package:fitkey_user/services/geo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('distance: 1 km north is ~1000 m', () {
    const a = LatLng(28.6139, 77.2090); // New Delhi
    final b = LatLng(28.6139 + 1000 / 111195, 77.2090);
    expect(Geo.distance(a, b), closeTo(1000, 2));
  });

  test('simplify keeps the ends and drops collinear points', () {
    final pts = [for (var i = 0; i <= 100; i++) LatLng(28.6 + i * 0.00001, 77.2)];
    final s = Geo.simplify(pts);
    expect(s.length, 2);
    expect(s.first, pts.first);
    expect(s.last, pts.last);
  });

  test('simplify keeps a real corner', () {
    final pts = [
      for (var i = 0; i <= 50; i++) LatLng(28.6 + i * 0.00002, 77.2),
      for (var i = 1; i <= 50; i++) LatLng(28.601, 77.2 + i * 0.00002),
    ];
    expect(Geo.simplify(pts).length, 3);
  });

  test('explored cells: a 1 km straight walk covers ~10–12 cells (~0.1 km²)', () {
    const a = LatLng(19.0760, 72.8777); // Mumbai
    final b = LatLng(19.0760 + 1000 / 111195, 72.8777);
    final cells = Geo.cellsOf([a, b]);
    expect(cells.length, inInclusiveRange(10, 13));
    expect(Geo.areaOf(cells), closeTo(cells.length * 10000, 0.1));
  });

  test('explored cells: a fast 20 km segment leaves no gaps', () {
    const a = LatLng(12.9716, 77.5946); // Bengaluru
    final b = LatLng(12.9716 + 20000 / 111195, 77.5946);
    final cells = Geo.cellsOf([a, b]);
    expect(cells.length, inInclusiveRange(200, 230));
  });

  test('formatting', () {
    expect(Geo.km(850), '850 m');
    expect(Geo.km(1234), '1.23 km');
    expect(Geo.area(10000), '1.0 ha');
    expect(Geo.area(2500000), '2.50 km²');
    expect(Geo.duration(65), '1:05');
    expect(Geo.duration(3725), '1h 02m');
    expect(Geo.pace(1000, 360, asSpeed: false), "6'00\" /km");
    expect(Geo.pace(10000, 1800, asSpeed: true), '20.0 km/h');
  });
}
