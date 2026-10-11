import 'package:fitkey_core/fitkey_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/partner_session.dart';

/// Listing wizard (BRD P2–P5): categories → details → location → timings → photos → facilities.
class VenueEditorScreen extends StatefulWidget {
  const VenueEditorScreen({super.key, this.existing});

  final PartnerVenue? existing;

  @override
  State<VenueEditorScreen> createState() => _VenueEditorScreenState();
}

class _VenueEditorScreenState extends State<VenueEditorScreen> {
  static const _titles = ['Category', 'Venue details', 'Location', 'Timings', 'Photos', 'Facilities'];
  static const minPhotos = 4;
  static const maxPhotos = 5;

  late final PartnerVenue _v = widget.existing == null ? PartnerVenue() : PartnerVenue.fromJson(_copy(widget.existing!));
  final _page = PageController();
  int _step = 0;
  bool _saving = false;
  final _forms = List.generate(3, (_) => GlobalKey<FormState>());

  bool get _isNew => _v.id == null;

  static Json _copy(PartnerVenue v) => {
        ...v.toJson(),
        'id': v.id,
        'status': switch (v.status) {
          VenueStatus.underReview => 'under_review',
          VenueStatus s => s.name,
        },
        'reviewNote': v.reviewNote,
        'description': v.description,
        'area': v.area,
        'contactPhone': v.contactPhone,
        'contactEmail': v.contactEmail,
      };

  String? _validateStep(int step) {
    switch (step) {
      case 0:
        return _v.categories.isEmpty ? 'Pick at least one category' : null;
      case 1:
      case 2:
        return _forms[step - 1].currentState?.validate() == false ? 'Please fix the highlighted fields' : null;
      case 3:
        if (_v.openDays.isEmpty) return 'Select the days you are open';
        return _v.closesAt.compareTo(_v.opensAt) <= 0 ? 'Closing time must be after opening time' : null;
      default:
        return null;
    }
  }

  void _go(int step) {
    if (step > _step) {
      for (var s = _step; s < step; s++) {
        final error = _validateStep(s);
        if (error != null) {
          showSnack(context, error, error: true);
          if (s != _step) _page.jumpToPage(s);
          setState(() => _step = s);
          return;
        }
      }
    }
    FocusScope.of(context).unfocus();
    setState(() => _step = step);
    _page.animateToPage(step, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  Future<void> _save({required bool submit}) async {
    for (var s = 0; s < _titles.length; s++) {
      final error = _validateStep(s);
      if (error != null) {
        _go(s);
        return showSnack(context, error, error: true);
      }
    }
    if (submit && _v.photos.length < minPhotos) {
      return showSnack(context, 'Add at least $minPhotos photos to submit', error: true);
    }
    setState(() => _saving = true);
    final api = context.read<PartnerSession>().api;
    try {
      var saved = _isNew ? await api.createVenue(_v) : await api.updateVenue(_v);
      _v.id = saved.id;
      if (submit && saved.status.canSubmit) saved = await api.submitVenue(saved.id!);
      if (!mounted) return;
      showSnack(
        context,
        submit
            ? 'Submitted! The FITKEY team will review your listing.'
            : (saved.status == VenueStatus.draft ? 'Draft saved' : 'Changes saved'),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        showSnack(context, errorMessage(e), error: true);
        setState(() => _saving = false);
      }
    }
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _step == _titles.length - 1;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'List your venue' : 'Edit listing'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Step ${_step + 1} of ${_titles.length} · ${_titles[_step]}',
                  style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (_step + 1) / _titles.length,
                  minHeight: 5,
                  backgroundColor: FkColors.surfaceHigh,
                ),
              ),
            ]),
          ),
        ),
      ),
      body: PageView(
        controller: _page,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _CategoryStep(venue: _v, onChanged: () => setState(() {})),
          _DetailsStep(venue: _v, formKey: _forms[0]),
          _LocationStep(venue: _v, formKey: _forms[1]),
          _TimingsStep(venue: _v, onChanged: () => setState(() {})),
          _PhotosStep(venue: _v, min: minPhotos, max: maxPhotos, onChanged: () => setState(() {})),
          _FacilitiesStep(venue: _v, onChanged: () => setState(() {})),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: last
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  if (_v.status.canSubmit)
                    FilledButton(
                      onPressed: _saving ? null : () => _save(submit: true),
                      child: Text(_saving ? 'Saving…' : 'Save & submit for review'),
                    ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(onPressed: _saving ? null : () => _go(_step - 1), child: const Text('Back')),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _v.status.canSubmit
                          ? OutlinedButton(
                              onPressed: _saving ? null : () => _save(submit: false),
                              child: const Text('Save draft'),
                            )
                          : FilledButton(
                              onPressed: _saving ? null : () => _save(submit: false),
                              child: Text(_saving ? 'Saving…' : 'Save changes'),
                            ),
                    ),
                  ]),
                ])
              : Row(children: [
                  if (_step > 0) ...[
                    Expanded(child: OutlinedButton(onPressed: () => _go(_step - 1), child: const Text('Back'))),
                    const SizedBox(width: 10),
                  ],
                  Expanded(flex: 2, child: FilledButton(onPressed: () => _go(_step + 1), child: const Text('Next'))),
                ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 1 — categories (P2, multi-select)
// ---------------------------------------------------------------------------
class _CategoryStep extends StatelessWidget {
  const _CategoryStep({required this.venue, required this.onChanged});

  final PartnerVenue venue;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _StepIntro('What kind of venue is it?', 'Select all that apply — members filter by these.'),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.5,
          children: venueCategories.entries.map((e) {
            final selected = venue.categories.contains(e.key);
            return InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () {
                selected ? venue.categories.remove(e.key) : venue.categories.add(e.key);
                onChanged();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: selected ? e.value.color.withValues(alpha: 0.18) : FkColors.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: selected ? e.value.color : FkColors.outline, width: selected ? 2 : 1),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(e.value.icon, color: e.value.color, size: 28),
                    const Spacer(),
                    if (selected) Icon(Icons.check_circle, color: e.value.color),
                  ]),
                  const Spacer(),
                  Text(e.value.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                ]),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Step 2 — name, description, contact (P3)
// ---------------------------------------------------------------------------
class _DetailsStep extends StatelessWidget {
  const _DetailsStep({required this.venue, required this.formKey});

  final PartnerVenue venue;
  final GlobalKey<FormState> formKey;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const _StepIntro('Tell members about your venue', 'This appears on your FITKEY listing.'),
          const _Label('Venue name *'),
          TextFormField(
            initialValue: venue.name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'e.g. Iron Paradise Gym'),
            onChanged: (v) => venue.name = v,
            validator: (v) => (v ?? '').trim().length < 2 ? 'Enter the venue name' : null,
          ),
          const _Label('Description'),
          TextFormField(
            initialValue: venue.description,
            maxLines: 4,
            maxLength: 2000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'What makes your place special? Classes, coaches, vibe…'),
            onChanged: (v) => venue.description = v,
          ),
          const _Label('Front-desk phone'),
          TextFormField(
            initialValue: venue.contactPhone,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]'))],
            decoration: const InputDecoration(hintText: '98765 43210', prefixIcon: Icon(Icons.call_outlined)),
            onChanged: (v) => venue.contactPhone = v,
            validator: (v) {
              final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
              return digits.isEmpty || digits.length >= 10 ? null : 'Enter a valid phone number';
            },
          ),
          const _Label('Venue email'),
          TextFormField(
            initialValue: venue.contactEmail,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(hintText: 'hello@yourgym.com', prefixIcon: Icon(Icons.mail_outline)),
            onChanged: (v) => venue.contactEmail = v,
            validator: (v) {
              final value = (v ?? '').trim();
              return value.isEmpty || RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)
                  ? null
                  : 'Enter a valid email';
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 3 — address + map location (P3)
// ---------------------------------------------------------------------------
class _LocationStep extends StatefulWidget {
  const _LocationStep({required this.venue, required this.formKey});

  final PartnerVenue venue;
  final GlobalKey<FormState> formKey;

  @override
  State<_LocationStep> createState() => _LocationStepState();
}

class _LocationStepState extends State<_LocationStep> {
  bool _locating = false;

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw 'Turn on location services and try again';
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw 'Location permission is needed to pin your venue';
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
      );
      setState(() {
        widget.venue.latitude = pos.latitude;
        widget.venue.longitude = pos.longitude;
      });
      if (mounted) showSnack(context, 'Location pinned');
    } catch (e) {
      if (mounted) showSnack(context, e is String ? e : 'Could not get your location', error: true);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    return Form(
      key: widget.formKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const _StepIntro('Where are you located?', 'Members search by area and distance.'),
          const _Label('Full address *'),
          TextFormField(
            initialValue: v.address,
            maxLines: 2,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'Building, street, landmark'),
            onChanged: (s) => v.address = s,
            validator: (s) => (s ?? '').trim().length < 5 ? 'Enter the full address' : null,
          ),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const _Label('Area / locality'),
                TextFormField(
                  initialValue: v.area,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(hintText: 'Indiranagar'),
                  onChanged: (s) => v.area = s,
                ),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const _Label('City *'),
                TextFormField(
                  initialValue: v.city,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(hintText: 'Bengaluru'),
                  onChanged: (s) => v.city = s,
                  validator: (s) => (s ?? '').trim().length < 2 ? 'Enter city' : null,
                ),
              ]),
            ),
          ]),
          const _Label('Map location'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(v.latitude == null ? Icons.location_off_outlined : Icons.location_on,
                      color: v.latitude == null ? FkColors.textSecondary : FkColors.lime),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      v.latitude == null
                          ? 'Not pinned yet'
                          : '${v.latitude!.toStringAsFixed(5)}, ${v.longitude!.toStringAsFixed(5)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                const Text('Stand at your venue entrance and tap below so members get accurate directions.',
                    style: TextStyle(color: FkColors.textSecondary, fontSize: 13)),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: _locating
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.my_location, color: FkColors.lime),
                  label: Text(v.latitude == null ? 'Use my current location' : 'Update location'),
                  onPressed: _locating ? null : _useCurrentLocation,
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 4 — opening hours & days (P3)
// ---------------------------------------------------------------------------
class _TimingsStep extends StatelessWidget {
  const _TimingsStep({required this.venue, required this.onChanged});

  final PartnerVenue venue;
  final VoidCallback onChanged;

  static const _days = {'mon': 'Mon', 'tue': 'Tue', 'wed': 'Wed', 'thu': 'Thu', 'fri': 'Fri', 'sat': 'Sat', 'sun': 'Sun'};

  TimeOfDay _parse(String hhmm) => TimeOfDay(hour: int.parse(hhmm.substring(0, 2)), minute: int.parse(hhmm.substring(3, 5)));
  String _fmt(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    Future<void> pick(bool opening) async {
      final t = await showTimePicker(context: context, initialTime: _parse(opening ? venue.opensAt : venue.closesAt));
      if (t == null) return;
      opening ? venue.opensAt = _fmt(t) : venue.closesAt = _fmt(t);
      onChanged();
    }

    Widget timeCard(String label, String value, VoidCallback onTap) => Expanded(
          child: Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: const TextStyle(color: FkColors.textSecondary, fontSize: 12)),
                  const SizedBox(height: 6),
                  Text(formatTimeOfDay('$value:00'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                ]),
              ),
            ),
          ),
        );

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _StepIntro('When are you open?', 'Members can only check in during these hours.'),
        Row(children: [
          timeCard('Opens at', venue.opensAt, () => pick(true)),
          const SizedBox(width: 12),
          timeCard('Closes at', venue.closesAt, () => pick(false)),
        ]),
        const _Label('Open on'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _days.entries.map((d) {
            final selected = venue.openDays.contains(d.key);
            return FilterChip(
              selected: selected,
              label: Text(d.value, style: TextStyle(color: selected ? Colors.black : null)),
              onSelected: (_) {
                selected ? venue.openDays.remove(d.key) : venue.openDays.add(d.key);
                onChanged();
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () {
            venue.openDays = _days.keys.toList();
            onChanged();
          },
          child: const Text('Open all 7 days'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Step 5 — photos (P4: 4–5 photos)
// ---------------------------------------------------------------------------
class _PhotosStep extends StatefulWidget {
  const _PhotosStep({required this.venue, required this.min, required this.max, required this.onChanged});

  final PartnerVenue venue;
  final int min;
  final int max;
  final VoidCallback onChanged;

  @override
  State<_PhotosStep> createState() => _PhotosStepState();
}

class _PhotosStepState extends State<_PhotosStep> {
  final _picker = ImagePicker();

  /// Uploads in progress: progress 0–1 per local file.
  final _uploading = <String, double>{};

  int get _remaining => widget.max - widget.venue.photos.length - _uploading.length;

  Future<void> _add(ImageSource source) async {
    final List<XFile> files;
    if (source == ImageSource.camera || _remaining == 1) {
      final f = await _picker.pickImage(source: source, maxWidth: 1600, imageQuality: 80);
      files = f == null ? [] : [f];
    } else {
      files = await _picker.pickMultiImage(maxWidth: 1600, imageQuality: 80, limit: _remaining);
    }
    for (final f in files.take(_remaining)) {
      _upload(f.path);
    }
  }

  Future<void> _upload(String path) async {
    if (!mounted) return;
    final api = context.read<PartnerSession>().api;
    setState(() => _uploading[path] = 0);
    try {
      final url = await api.uploadPhoto(path, onProgress: (p) {
        if (mounted) setState(() => _uploading[path] = p);
      });
      widget.venue.photos.add(url);
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _uploading.remove(path));
      widget.onChanged();
    }
  }

  void _pickSource() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () {
              Navigator.pop(ctx);
              _add(ImageSource.gallery);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () {
              Navigator.pop(ctx);
              _add(ImageSource.camera);
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.venue.photos;
    final count = photos.length;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _StepIntro('Show off your space',
            'Add ${widget.min}–${widget.max} bright, clear photos: entrance, main floor, equipment, changing rooms. '
            'The first photo is your cover.'),
        Text('$count of ${widget.max} added',
            style: TextStyle(
                fontWeight: FontWeight.w700, color: count >= widget.min ? FkColors.lime : FkColors.orange)),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.3,
          children: [
            for (var i = 0; i < photos.length; i++)
              Stack(fit: StackFit.expand, children: [
                VenueImage(url: photos[i], borderRadius: 14),
                if (i == 0)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: FkColors.lime, borderRadius: BorderRadius.circular(10)),
                      child: const Text('COVER',
                          style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w800)),
                    ),
                  ),
                Positioned(
                  right: 4,
                  top: 4,
                  child: PopupMenuButton<String>(
                    icon: const CircleAvatar(
                        radius: 14, backgroundColor: Colors.black54, child: Icon(Icons.more_vert, size: 16, color: Colors.white)),
                    onSelected: (action) {
                      setState(() {
                        final url = photos.removeAt(i);
                        if (action == 'cover') photos.insert(0, url);
                      });
                      widget.onChanged();
                    },
                    itemBuilder: (_) => [
                      if (i != 0) const PopupMenuItem(value: 'cover', child: Text('Make cover photo')),
                      const PopupMenuItem(value: 'remove', child: Text('Remove')),
                    ],
                  ),
                ),
              ]),
            for (final p in _uploading.values)
              Container(
                decoration: BoxDecoration(color: FkColors.surface, borderRadius: BorderRadius.circular(14)),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(value: p == 0 ? null : p),
                    const SizedBox(height: 8),
                    const Text('Uploading…', style: TextStyle(fontSize: 12, color: FkColors.textSecondary)),
                  ]),
                ),
              ),
            if (_remaining > 0)
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _pickSource,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: FkColors.lime.withValues(alpha: 0.5), width: 1.5),
                    color: FkColors.lime.withValues(alpha: 0.06),
                  ),
                  child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.add_a_photo_outlined, color: FkColors.lime, size: 30),
                    SizedBox(height: 6),
                    Text('Add photos', style: TextStyle(color: FkColors.lime, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Step 6 — trainer, equipment, amenities (P5)
// ---------------------------------------------------------------------------
class _FacilitiesStep extends StatefulWidget {
  const _FacilitiesStep({required this.venue, required this.onChanged});

  final PartnerVenue venue;
  final VoidCallback onChanged;

  @override
  State<_FacilitiesStep> createState() => _FacilitiesStepState();
}

class _FacilitiesStepState extends State<_FacilitiesStep> {
  final _equipment = TextEditingController();

  static const _suggestions = [
    'Treadmills',
    'Dumbbells',
    'Squat racks',
    'Bench press',
    'Cable machines',
    'Spin bikes',
    'Rowing machines',
    'Yoga mats',
    'Punching bags',
    'Boxing ring',
    'Badminton courts',
    'Swimming lanes',
  ];

  void _addEquipment(String item) {
    final value = item.trim();
    if (value.isEmpty || widget.venue.equipment.contains(value)) return;
    setState(() => widget.venue.equipment.add(value));
    _equipment.clear();
    widget.onChanged();
  }

  @override
  void dispose() {
    _equipment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _StepIntro('Facilities & features', 'Help members know what to expect.'),
        Card(
          child: SwitchListTile(
            value: v.trainerAvailable,
            activeThumbColor: FkColors.lime,
            title: const Text('Trainer available', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('A coach is on the floor to guide members'),
            onChanged: (on) {
              setState(() => v.trainerAvailable = on);
              widget.onChanged();
            },
          ),
        ),
        const _Label('Amenities'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: amenityLabels.entries.map((a) {
            final selected = v.amenities.contains(a.key);
            return FilterChip(
              selected: selected,
              avatar: Icon(a.value.$2, size: 16, color: selected ? Colors.black : FkColors.textSecondary),
              label: Text(a.value.$1, style: TextStyle(color: selected ? Colors.black : null)),
              onSelected: (_) {
                setState(() => selected ? v.amenities.remove(a.key) : v.amenities.add(a.key));
                widget.onChanged();
              },
            );
          }).toList(),
        ),
        const _Label('Equipment'),
        TextField(
          controller: _equipment,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'Add equipment, e.g. Leg press',
            suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: () => _addEquipment(_equipment.text)),
          ),
          onSubmitted: _addEquipment,
        ),
        const SizedBox(height: 10),
        if (v.equipment.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: v.equipment
                .map((e) => InputChip(
                      label: Text(e),
                      onDeleted: () {
                        setState(() => v.equipment.remove(e));
                        widget.onChanged();
                      },
                    ))
                .toList(),
          ),
        const SizedBox(height: 12),
        const Text('Quick add', style: TextStyle(color: FkColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: _suggestions
              .where((s) => !v.equipment.contains(s))
              .map((s) => ActionChip(label: Text('+ $s'), onPressed: () => _addEquipment(s)))
              .toList(),
        ),
      ],
    );
  }
}

class _StepIntro extends StatelessWidget {
  const _StepIntro(this.title, this.subtitle);

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(subtitle, style: const TextStyle(color: FkColors.textSecondary, height: 1.4)),
      ]),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      );
}
