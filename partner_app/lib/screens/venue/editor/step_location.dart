part of '../venue_editor_screen.dart';

// ---------------------------------------------------------------------------
// Step 3 — address + map pin (OpenStreetMap, Nominatim search, GPS)
// ---------------------------------------------------------------------------
class _LocationStep extends StatefulWidget {
  const _LocationStep({required this.venue, required this.formKey, required this.onChanged});

  final PartnerVenue venue;
  final GlobalKey<FormState> formKey;
  final VoidCallback onChanged;

  @override
  State<_LocationStep> createState() => _LocationStepState();
}

class _LocationStepState extends State<_LocationStep> {
  late final _address = TextEditingController(text: widget.venue.address);
  late final _area = TextEditingController(text: widget.venue.area);
  late final _city = TextEditingController(text: widget.venue.city);

  bool _locating = false;

  @override
  void initState() {
    super.initState();
    // No pin yet: take the partner's current location straight away (they usually list from their venue).
    if (widget.venue.latitude == null || widget.venue.longitude == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _useCurrentLocation(auto: true));
    }
  }

  /// GPS → map pin, and fills empty address / area / city from the reverse-geocoded place.
  Future<void> _useCurrentLocation({bool auto = false}) async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (!auto && mounted) toast(context, 'Turn on location (GPS) to use your current location', error: true);
        if (!auto) await Geolocator.openLocationSettings();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (!auto && mounted) toast(context, 'Allow location for FITKEY Partner in Settings to use this', error: true);
        if (perm == LocationPermission.deniedForever && !auto) await Geolocator.openAppSettings();
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
      );
      final v = widget.venue;
      PlaceResult? place;
      try {
        place = await PlaceSearch().reverse(pos.latitude, pos.longitude);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        v.latitude = double.parse(pos.latitude.toStringAsFixed(6));
        v.longitude = double.parse(pos.longitude.toStringAsFixed(6));
        // Only fill blanks — never overwrite what the partner typed.
        if (place != null) {
          if (v.area.trim().isEmpty && place.area != null) _area.text = v.area = place.area!;
          if (v.city.trim().isEmpty && place.city != null) _city.text = v.city = place.city!;
          if (v.address.trim().isEmpty) {
            final line = [place.road, place.area, if (place.postcode != null) place.postcode].whereType<String>().join(', ');
            _address.text = v.address = line.isNotEmpty ? line : place.displayName;
          }
        }
      });
      widget.onChanged();
      toast(context, 'Current location added — adjust the pin if needed', icon: Icons.my_location_rounded);
    } catch (_) {
      if (!auto && mounted) toast(context, 'Could not get your location. Try again outdoors or drop the pin.', error: true);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _area.dispose();
    _city.dispose();
    super.dispose();
  }

  Future<void> _openPicker() async {
    final v = widget.venue;
    final query = [v.address, v.area, v.city].where((s) => s.trim().isNotEmpty).join(', ');
    final picked = await push<PickedLocation>(
      context,
      LocationPickerScreen(lat: v.latitude, lng: v.longitude, initialQuery: query),
    );
    if (picked == null || !mounted) return;
    setState(() {
      v.latitude = double.parse(picked.lat.toStringAsFixed(6));
      v.longitude = double.parse(picked.lng.toStringAsFixed(6));
      final p = picked.place;
      // Only fill blanks — never overwrite what the partner typed.
      if (p != null) {
        if (v.area.trim().isEmpty && p.area != null) _area.text = v.area = p.area!;
        if (v.city.trim().isEmpty && p.city != null) _city.text = v.city = p.city!;
        if (v.address.trim().isEmpty && p.road != null) {
          _address.text = v.address = [p.road, p.area, if (p.postcode != null) p.postcode].whereType<String>().join(', ');
        }
      }
    });
    widget.onChanged();
    toast(context, 'Location pinned', icon: Icons.location_on_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    final pinned = v.latitude != null && v.longitude != null;
    return Form(
      key: widget.formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _StepIntro('Where are you located?', 'Members search by area and distance.'),
          TextFormField(
            controller: _address,
            maxLines: 2,
            minLines: 1,
            textCapitalization: TextCapitalization.words,
            autofillHints: const [AutofillHints.fullStreetAddress],
            decoration: const InputDecoration(
              labelText: 'Full address *',
              hintText: 'Building, street, landmark',
              prefixIcon: Icon(Icons.home_work_outlined),
            ),
            onChanged: (s) {
              v.address = s;
              widget.onChanged();
            },
            validator: (s) => null, // optional when the map pin / current location is set
          ),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextFormField(
                controller: _area,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Area / locality', hintText: 'Indiranagar'),
                onChanged: (s) {
                  v.area = s;
                  widget.onChanged();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _city,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.addressCity],
                decoration: const InputDecoration(labelText: 'City *', hintText: 'Bengaluru'),
                onChanged: (s) {
                  v.city = s;
                  widget.onChanged();
                },
                validator: (s) => (s ?? '').trim().length < 2 ? 'Enter city' : null,
              ),
            ),
          ]),
          const SizedBox(height: 18),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                IconBubble(pinned ? Icons.location_on_rounded : Icons.add_location_alt_rounded,
                    color: pinned ? AppColors.green : AppColors.primary, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(pinned ? 'Map pin set' : 'Drop a pin on the map',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    Text(
                      pinned
                          ? '${v.latitude!.toStringAsFixed(5)}, ${v.longitude!.toStringAsFixed(5)}'
                          : 'Powers "near me" search and directions',
                      style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                    ),
                  ]),
                ),
                if (pinned) const Tag('PINNED', color: AppColors.green, dense: true),
              ]),
              const SizedBox(height: 12),
              if (pinned)
                MapPreview(lat: v.latitude!, lng: v.longitude!, onTap: _openPicker)
              else
                Tap(
                  onTap: _openPicker,
                  child: Container(
                    height: 130,
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.primary.withValues(alpha: 0.4), width: 1.5),
                    ),
                    child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.map_rounded, color: AppColors.primary, size: 34),
                      SizedBox(height: 8),
                      Text('Search or pin on map',
                          style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800)),
                      SizedBox(height: 2),
                      Text('Use search, drag the map, or your current location',
                          style: TextStyle(color: AppColors.text2, fontSize: 12)),
                    ]),
                  ),
                ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _locating ? null : () => _useCurrentLocation(),
                icon: _locating
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.my_location_rounded),
                label: Text(_locating ? 'Finding you…' : 'Use my current location'),
              ),
              const SizedBox(height: 10),
              const Text('Tip: stand at your entrance and use "my location" for the most accurate pin.',
                  style: TextStyle(color: AppColors.text3, fontSize: 12, height: 1.4)),
            ]),
          ),
        ],
      ),
    );
  }
}
