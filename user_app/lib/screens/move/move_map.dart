import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/geo.dart';
import '../../ui/ui.dart';

/// OpenStreetMap view of routes plus the ~100 m cells they explored.
class MoveMap extends StatefulWidget {
  const MoveMap({
    super.key,
    this.paths = const [],
    this.cells = const {},
    this.current,
    this.follow = false,
    this.interactive = true,
    this.fallbackCenter,
  });

  final List<List<LatLng>> paths;
  final Set<(int, int)> cells;

  /// Live position marker (while recording).
  final LatLng? current;

  /// Keep the camera on [current].
  final bool follow;
  final bool interactive;
  final LatLng? fallbackCenter;

  @override
  State<MoveMap> createState() => _MoveMapState();
}

class _MoveMapState extends State<MoveMap> {
  final _map = MapController();
  bool _ready = false;

  static const _india = LatLng(22.5, 79.0);

  List<LatLng> get _all => [for (final p in widget.paths) ...p, if (widget.current != null) widget.current!];

  @override
  void didUpdateWidget(MoveMap old) {
    super.didUpdateWidget(old);
    if (!_ready) return;
    if (widget.follow && widget.current != null && widget.current != old.current) {
      _map.move(widget.current!, _map.camera.zoom < 15 ? 16.5 : _map.camera.zoom);
    } else if (!widget.follow && old.paths.length != widget.paths.length) {
      _fit();
    }
  }

  void _fit() {
    final pts = _all;
    if (pts.length >= 2) {
      final b = LatLngBounds.fromPoints(pts);
      if (b.north - b.south < 1e-5 && b.east - b.west < 1e-5) {
        _map.move(pts.first, 16);
      } else {
        _map.fitCamera(CameraFit.bounds(bounds: b, padding: const EdgeInsets.all(36), maxZoom: 17));
      }
    } else if (pts.length == 1) {
      _map.move(pts.first, 16);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pts = _all;
    final center = widget.current ?? (pts.isNotEmpty ? pts.last : widget.fallbackCenter ?? _india);
    final cellList = widget.cells.length > 4000 ? widget.cells.take(4000) : widget.cells;
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: center,
        initialZoom: pts.isNotEmpty || widget.fallbackCenter != null ? 15 : 4.2,
        interactionOptions: InteractionOptions(
          flags: widget.interactive ? InteractiveFlag.all & ~InteractiveFlag.rotate : InteractiveFlag.none,
        ),
        onMapReady: () {
          _ready = true;
          if (!widget.follow) _fit();
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.fitkey.fitkey_user',
          maxZoom: 19,
        ),
        if (cellList.isNotEmpty)
          PolygonLayer(
            polygons: [
              for (final c in cellList)
                Polygon(
                  points: Geo.cellPolygon(c),
                  color: AppColors.primary.withValues(alpha: 0.18),
                  borderColor: AppColors.primary.withValues(alpha: 0.35),
                  borderStrokeWidth: 0.6,
                ),
            ],
          ),
        PolylineLayer(
          polylines: [
            for (final p in widget.paths)
              if (p.length >= 2)
                Polyline(
                  points: p,
                  strokeWidth: 4.5,
                  color: AppColors.primary,
                  borderStrokeWidth: 1.5,
                  borderColor: Colors.white,
                ),
          ],
        ),
        MarkerLayer(markers: [
          for (final p in widget.paths)
            if (p.isNotEmpty && widget.current == null)
              Marker(point: p.first, width: 14, height: 14, child: const _Dot(color: AppColors.green)),
          if (widget.current != null)
            Marker(point: widget.current!, width: 26, height: 26, child: const _Dot(color: AppColors.blue, pulse: true)),
        ]),
        SimpleAttributionWidget(
          source: const Text('OpenStreetMap', style: TextStyle(fontSize: 10)),
          onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
          backgroundColor: Colors.white70,
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, this.pulse = false});
  final Color color;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: pulse ? color.withValues(alpha: 0.25) : null,
      ),
      padding: EdgeInsets.all(pulse ? 6 : 0),
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
      ),
    );
  }
}
