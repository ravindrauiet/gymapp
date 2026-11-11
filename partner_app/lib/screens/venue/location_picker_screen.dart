import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/ui.dart';
import '../../widgets/listing/place_search.dart';

/// Result of the pin-drop picker: the pinned point and (when known) its address parts.
typedef PickedLocation = ({double lat, double lng, PlaceResult? place});

const _defaultCenter = LatLng(12.9716, 77.5946); // Bengaluru

/// OpenStreetMap tile layer + attribution shared by the inline preview and the full-screen picker.
List<Widget> osmLayers() => [
      TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: osmUserAgentPackage,
        maxZoom: 19,
      ),
      RichAttributionWidget(
        alignment: AttributionAlignment.bottomLeft,
        attributions: [
          TextSourceAttribution(
            'OpenStreetMap contributors',
            onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
          ),
        ],
      ),
    ];

/// Small non-interactive map preview with the venue pin. Tap opens the full picker.
class MapPreview extends StatelessWidget {
  const MapPreview({super.key, required this.lat, required this.lng, this.height = 170, this.onTap});

  final double lat;
  final double lng;
  final double height;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final point = LatLng(lat, lng);
    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(children: [
          FlutterMap(
            key: ValueKey('$lat,$lng'),
            options: MapOptions(
              initialCenter: point,
              initialZoom: 16,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
              onTap: onTap == null ? null : (_, _) => onTap!(),
            ),
            children: [
              ...osmLayers().take(1),
              MarkerLayer(markers: [
                Marker(point: point, width: 44, height: 44, alignment: Alignment.topCenter, child: const _Pin()),
              ]),
              ...osmLayers().skip(1),
            ],
          ),
          if (onTap != null)
            Positioned(
              right: 10,
              top: 10,
              child: Tap(
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), boxShadow: AppShadows.soft),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.edit_location_alt_rounded, size: 16, color: AppColors.primary),
                    SizedBox(width: 4),
                    Text('Adjust pin', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppColors.primary)),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Full-screen pin-drop: search an address (Nominatim, debounced), drag the map under the centre pin or use the
/// phone's GPS, then confirm. Returns a [PickedLocation].
class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key, this.lat, this.lng, this.initialQuery = ''});

  final double? lat;
  final double? lng;
  final String initialQuery;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final _map = MapController();
  final _search = PlaceSearch();
  late final _query = TextEditingController(text: widget.initialQuery);
  final _focus = FocusNode();
  Timer? _debounce;
  int _seq = 0;

  late LatLng _center = widget.lat != null && widget.lng != null ? LatLng(widget.lat!, widget.lng!) : _defaultCenter;
  late bool _hasPin = widget.lat != null && widget.lng != null;
  List<PlaceResult> _results = const [];
  PlaceResult? _place;
  bool _searching = false;
  bool _locating = false;
  bool _confirming = false;
  bool _moving = false;
  String? _searchError;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    // No pin yet: try to centre on the address typed in step 3.
    if (!_hasPin && widget.initialQuery.trim().length >= 3) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runSearch(widget.initialQuery, jumpToFirst: true));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    _map.dispose();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 3) {
      setState(() {
        _results = const [];
        _searchError = null;
      });
      return;
    }
    // Nominatim allows one request per second; wait until typing pauses.
    _debounce = Timer(const Duration(milliseconds: 700), () => _runSearch(q));
  }

  Future<void> _runSearch(String q, {bool jumpToFirst = false}) async {
    final seq = ++_seq;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final r = await _search.search(q);
      if (!mounted || seq != _seq) return;
      setState(() => _results = jumpToFirst ? const [] : r);
      if (jumpToFirst && r.isNotEmpty) _choose(r.first, keepFocus: false);
      if (!jumpToFirst && r.isEmpty) setState(() => _searchError = 'No places found. Try the area or landmark name.');
    } catch (_) {
      if (mounted && seq == _seq) setState(() => _searchError = 'Search is unavailable right now. Drag the map instead.');
    } finally {
      if (mounted && seq == _seq) setState(() => _searching = false);
    }
  }

  void _choose(PlaceResult p, {bool keepFocus = false}) {
    if (!keepFocus) _focus.unfocus();
    final point = LatLng(p.lat, p.lng);
    setState(() {
      _results = const [];
      _place = p;
      _center = point;
      _hasPin = true;
    });
    _map.move(point, 17);
  }

  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw 'Turn on location services and try again';
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw 'Allow location access to pin your venue';
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
      );
      if (!mounted) return;
      final point = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _center = point;
        _place = null;
        _hasPin = true;
      });
      _map.move(point, 18);
    } catch (e) {
      if (mounted) toast(context, e is String ? e : 'Could not get your location', error: true);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _confirm() async {
    setState(() => _confirming = true);
    PlaceResult? place = _place;
    // Fill area / city from the pin when it moved away from the chosen search result.
    if (place == null || (place.lat - _center.latitude).abs() > 0.0005 || (place.lng - _center.longitude).abs() > 0.0005) {
      try {
        place = await _search.reverse(_center.latitude, _center.longitude).timeout(const Duration(seconds: 6));
      } catch (_) {
        place = null;
      }
    }
    if (!mounted) return;
    Navigator.pop<PickedLocation>(context, (lat: _center.latitude, lng: _center.longitude, place: place));
  }

  @override
  Widget build(BuildContext context) {
    final showResults = _focus.hasFocus && (_results.isNotEmpty || _searchError != null);
    return Scaffold(
      appBar: AppBar(title: const Text('Pin your venue')),
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _center,
            initialZoom: _hasPin ? 17 : 12,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            onTap: (_, point) {
              _focus.unfocus();
              setState(() {
                _center = point;
                _place = null;
                _hasPin = true;
              });
              _map.move(point, _map.camera.zoom);
            },
            onPositionChanged: (camera, hasGesture) {
              if (!hasGesture) return;
              setState(() {
                _center = camera.center;
                _place = null;
                _hasPin = true;
                _moving = true;
              });
            },
            onMapEvent: (e) {
              if ((e is MapEventMoveEnd || e is MapEventFlingAnimationEnd) && _moving) setState(() => _moving = false);
            },
          ),
          children: osmLayers(),
        ),
        // Centre pin: the map moves under it.
        IgnorePointer(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 44),
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 150),
                offset: Offset(0, _moving ? -0.15 : 0),
                child: const _Pin(size: 48),
              ),
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          top: 12,
          child: Column(children: [
            Material(
              elevation: 3,
              shadowColor: Colors.black26,
              borderRadius: BorderRadius.circular(14),
              child: TextField(
                controller: _query,
                focusNode: _focus,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search area, street or landmark',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : (_query.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                _query.clear();
                                _onQueryChanged('');
                              },
                            )),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
                onChanged: (q) {
                  setState(() {});
                  _onQueryChanged(q);
                },
                onSubmitted: (q) {
                  _debounce?.cancel();
                  _runSearch(q);
                  _focus.requestFocus();
                },
              ),
            ),
            if (showResults)
              Container(
                margin: const EdgeInsets.only(top: 8),
                constraints: const BoxConstraints(maxHeight: 320),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), boxShadow: AppShadows.card),
                child: _searchError != null
                    ? Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(_searchError!, style: const TextStyle(color: AppColors.text2)),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _results.length,
                        separatorBuilder: (_, _) => const Divider(height: 1, indent: 52),
                        itemBuilder: (_, i) {
                          final p = _results[i];
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.place_outlined, color: AppColors.primary),
                            title: Text(p.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text(p.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                            onTap: () => _choose(p),
                          );
                        },
                      ),
              ),
          ]),
        ),
        Positioned(
          right: 14,
          bottom: 16,
          child: FloatingActionButton.small(
            heroTag: 'my-location',
            tooltip: 'Use my location',
            backgroundColor: Colors.white,
            onPressed: _locating ? null : _useMyLocation,
            child: _locating
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.my_location_rounded, color: AppColors.primary),
          ),
        ),
      ]),
      bottomNavigationBar: BottomActionBar(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.location_on_rounded, color: AppColors.primary, size: 20),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _place?.displayName ??
                    (_hasPin
                        ? '${_center.latitude.toStringAsFixed(5)}, ${_center.longitude.toStringAsFixed(5)}'
                        : 'Drag the map to put the pin on your entrance'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          AppButton(
            label: 'Confirm location',
            icon: Icons.check_rounded,
            busy: _confirming,
            onPressed: _hasPin ? _confirm : null,
          ),
        ]),
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.location_on_rounded,
        size: size, color: AppColors.primary, shadows: const [Shadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 3))]);
  }
}
