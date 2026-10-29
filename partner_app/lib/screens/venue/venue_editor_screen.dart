import 'package:fitkey_core/fitkey_core.dart' show amenityLabels, formatTimeOfDay;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../../widgets/status.dart';

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Same rule as the backend's phoneSchema: 10 digits, or + and 10–15 digits (spaces / dashes ignored).
bool _validPhone(String s) => RegExp(r'^(\+\d{10,15}|\d{10})$').hasMatch(s.replaceAll(RegExp(r'[\s-]'), ''));

/// Listing wizard (BRD P2–P5): category → details → location → timings → photos → facilities → review.
class VenueEditorScreen extends StatefulWidget {
  const VenueEditorScreen({super.key, this.existing});

  final PartnerVenue? existing;

  @override
  State<VenueEditorScreen> createState() => _VenueEditorScreenState();
}

class _VenueEditorScreenState extends State<VenueEditorScreen> {
  static const _titles = ['Category', 'Details', 'Location', 'Timings', 'Photos', 'Facilities', 'Review'];
  static const minPhotos = 4;
  static const maxPhotos = 5;

  late final PartnerVenue _v = widget.existing?.copy() ?? PartnerVenue();
  final _page = PageController();
  final _forms = {1: GlobalKey<FormState>(), 2: GlobalKey<FormState>()};
  int _step = 0;
  bool _saving = false;
  bool _dirty = false;
  int _uploads = 0;

  bool get _isNew => _v.id == null;
  int get _last => _titles.length - 1;

  void _changed() => setState(() => _dirty = true);

  /// Validates the data itself (pages that aren't on screen have no live form state).
  String? _validateStep(int step) {
    final v = _v;
    switch (step) {
      case 0:
        return v.categories.isEmpty ? 'Pick at least one category' : null;
      case 1:
        if (v.name.trim().length < 2) return 'Enter the venue name';
        if (v.contactPhone.trim().isNotEmpty && !_validPhone(v.contactPhone)) return 'Enter a valid front-desk phone';
        if (v.contactEmail.trim().isNotEmpty && !_emailRe.hasMatch(v.contactEmail.trim())) return 'Enter a valid venue email';
        return null;
      case 2:
        if (v.address.trim().length < 5) return 'Enter the full address';
        if (v.city.trim().length < 2) return 'Enter the city';
        return null;
      case 3:
        if (v.openDays.isEmpty) return 'Select the days you are open';
        return v.closesAt.compareTo(v.opensAt) <= 0 ? 'Closing time must be after opening time' : null;
      case 4:
        return _uploads > 0 ? 'Wait for photos to finish uploading' : null;
      default:
        return null;
    }
  }

  void _jump(int step) {
    FocusScope.of(context).unfocus();
    setState(() => _step = step);
    _page.animateToPage(step, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  /// Moves to [step], stopping at the first earlier step that has a problem.
  bool _go(int step) {
    if (step > _step) {
      for (var s = 0; s < step; s++) {
        final error = _validateStep(s);
        if (error != null) {
          toast(context, error, error: true);
          if (s != _step) _jump(s);
          // Highlight the offending fields once the page is on screen.
          WidgetsBinding.instance.addPostFrameCallback((_) => _forms[s]?.currentState?.validate());
          return false;
        }
      }
    }
    _jump(step);
    return true;
  }

  Future<void> _save({required bool submit}) async {
    if (_saving) return;
    for (var s = 0; s < _last; s++) {
      final error = _validateStep(s);
      if (error != null) {
        toast(context, error, error: true);
        _jump(s);
        WidgetsBinding.instance.addPostFrameCallback((_) => _forms[s]?.currentState?.validate());
        return;
      }
    }
    if (submit && _v.photos.length < minPhotos) {
      toast(context, 'Add at least $minPhotos photos to submit', error: true);
      _jump(4);
      return;
    }
    setState(() => _saving = true);
    final api = context.read<PartnerSession>().api;
    try {
      var saved = _isNew ? await api.createVenue(_v) : await api.updateVenue(_v);
      _v.id = saved.id;
      if (submit && saved.status.canSubmit) saved = await api.submitVenue(saved.id!);
      if (!mounted) return;
      toast(
        context,
        submit
            ? 'Submitted! The FITKEY team will review your listing.'
            : (saved.status == VenueStatus.draft ? 'Draft saved' : 'Changes saved'),
      );
      _dirty = false;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        toast(context, friendlyError(e), error: true);
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _confirmDiscard() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to this listing haven\'t been saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      setState(() => _dirty = false);
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _saving || (_step == 0 && !_dirty),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_step > 0) {
          _jump(_step - 1);
        } else {
          _confirmDiscard();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded),
            onPressed: _saving ? null : (_dirty ? _confirmDiscard : () => Navigator.pop(context)),
          ),
          title: Text(_isNew ? 'List your venue' : 'Edit listing'),
          actions: [
            if (_step < _last)
              TextButton(onPressed: _saving ? null : () => _go(_last), child: const Text('Review')),
            const SizedBox(width: 4),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(46),
            child: _StepHeader(titles: _titles, step: _step, onTap: (s) => s < _step ? _jump(s) : _go(s)),
          ),
        ),
        body: PageView(
          controller: _page,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _CategoryStep(venue: _v, onChanged: _changed),
            _DetailsStep(venue: _v, formKey: _forms[1]!, onChanged: _changed),
            _LocationStep(venue: _v, formKey: _forms[2]!, onChanged: _changed),
            _TimingsStep(venue: _v, onChanged: _changed),
            _PhotosStep(
              venue: _v,
              min: minPhotos,
              max: maxPhotos,
              onChanged: _changed,
              onUploading: (n) => setState(() => _uploads = n),
            ),
            _FacilitiesStep(venue: _v, onChanged: _changed),
            _ReviewStep(venue: _v, minPhotos: minPhotos, onEdit: _jump, problems: [
              for (var s = 0; s < _last; s++)
                if (_validateStep(s) case final e?) (step: s, message: e),
            ]),
          ],
        ),
        bottomNavigationBar: BottomActionBar(
          child: _step == _last
              ? (_v.status.canSubmit
                  ? Row(children: [
                      Expanded(
                        child: SizedBox(
                          height: 54,
                          child: OutlinedButton(
                            onPressed: _saving ? null : () => _save(submit: false),
                            child: const Text('Save draft'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: AppButton(
                          label: 'Submit for review',
                          icon: Icons.send_rounded,
                          busy: _saving,
                          onPressed: () => _save(submit: true),
                        ),
                      ),
                    ])
                  : AppButton(
                      label: 'Save changes',
                      icon: Icons.check_rounded,
                      busy: _saving,
                      onPressed: () => _save(submit: false),
                    ))
              : Row(children: [
                  if (_step > 0) ...[
                    SizedBox(
                      width: 54,
                      height: 54,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(54, 54)),
                        onPressed: () => _jump(_step - 1),
                        child: const Icon(Icons.arrow_back_rounded),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: AppButton(
                      label: _step == _last - 1 ? 'Review listing' : 'Next · ${_titles[_step + 1]}',
                      trailing: const Icon(Icons.arrow_forward_rounded, size: 20),
                      onPressed: () => _go(_step + 1),
                    ),
                  ),
                ]),
        ),
      ),
    );
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.titles, required this.step, required this.onTap});

  final List<String> titles;
  final int step;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Step ${step + 1} of ${titles.length}',
              style: const TextStyle(color: AppColors.primary, fontSize: 12.5, fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Text('· ${titles[step]}', style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          for (var i = 0; i < titles.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onTap(i),
                child: Padding(
                  padding: EdgeInsets.only(right: i == titles.length - 1 ? 0 : 4, top: 4, bottom: 4),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    height: 5,
                    decoration: BoxDecoration(
                      color: i <= step ? AppColors.primary : AppColors.line,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ]),
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
      padding: const EdgeInsets.all(16),
      children: [
        const _StepIntro('What kind of venue is it?', 'Select all that apply — members filter by these.'),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.25,
          children: venueVisuals.map((e) {
            final v = e.value;
            final selected = venue.categories.contains(e.key);
            return Tap(
              onTap: () {
                selected ? venue.categories.remove(e.key) : venue.categories.add(e.key);
                onChanged();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: selected ? AppColors.primary : Colors.transparent, width: 3),
                  boxShadow: selected ? AppShadows.glow(AppColors.primary) : AppShadows.soft,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(17),
                  child: Stack(fit: StackFit.expand, children: [
                    Image.asset(v.image, fit: BoxFit.cover),
                    PhotoScrim(strength: selected ? 0.85 : 0.7),
                    Positioned(
                      left: 12,
                      bottom: 12,
                      right: 12,
                      child: Row(children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(color: v.color, borderRadius: BorderRadius.circular(10)),
                          child: Icon(v.icon, color: Colors.white, size: 16),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(v.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                        ),
                      ]),
                    ),
                    Positioned(
                      top: 10,
                      right: 10,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected ? AppColors.primary : Colors.black.withValues(alpha: 0.25),
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: selected ? const Icon(Icons.check_rounded, size: 15, color: Colors.white) : null,
                      ),
                    ),
                  ]),
                ),
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
  const _DetailsStep({required this.venue, required this.formKey, required this.onChanged});

  final PartnerVenue venue;
  final GlobalKey<FormState> formKey;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _StepIntro('Tell members about your venue', 'This appears on your FITKEY listing.'),
          TextFormField(
            initialValue: venue.name,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Venue name *',
              hintText: 'e.g. Iron Paradise Gym',
              prefixIcon: Icon(Icons.storefront_rounded),
            ),
            onChanged: (v) {
              venue.name = v;
              onChanged();
            },
            validator: (v) => (v ?? '').trim().length < 2 ? 'Enter the venue name' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: venue.description,
            maxLines: 5,
            minLines: 3,
            maxLength: 2000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Description',
              alignLabelWithHint: true,
              hintText: 'What makes your place special? Classes, coaches, vibe…',
            ),
            onChanged: (v) {
              venue.description = v;
              onChanged();
            },
          ),
          const SizedBox(height: 6),
          TextFormField(
            initialValue: venue.contactPhone,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ -]'))],
            decoration: const InputDecoration(
              labelText: 'Front-desk phone',
              hintText: '98765 43210',
              prefixIcon: Icon(Icons.call_outlined),
            ),
            onChanged: (v) {
              venue.contactPhone = v;
              onChanged();
            },
            validator: (v) => (v ?? '').trim().isEmpty || _validPhone(v!) ? null : 'Enter a valid phone number',
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: venue.contactEmail,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Venue email',
              hintText: 'hello@yourgym.com',
              prefixIcon: Icon(Icons.mail_outline_rounded),
            ),
            onChanged: (v) {
              venue.contactEmail = v;
              onChanged();
            },
            validator: (v) {
              final value = (v ?? '').trim();
              return value.isEmpty || _emailRe.hasMatch(value) ? null : 'Enter a valid email';
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
  const _LocationStep({required this.venue, required this.formKey, required this.onChanged});

  final PartnerVenue venue;
  final GlobalKey<FormState> formKey;
  final VoidCallback onChanged;

  @override
  State<_LocationStep> createState() => _LocationStepState();
}

class _LocationStepState extends State<_LocationStep> {
  bool _locating = false;

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const _UserMessage('Turn on location services and try again');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw const _UserMessage('Location permission is needed to pin your venue');
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
      );
      if (!mounted) return;
      setState(() {
        widget.venue.latitude = pos.latitude;
        widget.venue.longitude = pos.longitude;
      });
      widget.onChanged();
      toast(context, 'Location pinned', icon: Icons.location_on_rounded);
    } catch (e) {
      if (mounted) toast(context, e is _UserMessage ? e.message : 'Could not get your location', error: true);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    final pinned = v.latitude != null && v.longitude != null;
    void changed() => widget.onChanged();
    return Form(
      key: widget.formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _StepIntro('Where are you located?', 'Members search by area and distance.'),
          TextFormField(
            initialValue: v.address,
            maxLines: 2,
            minLines: 1,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Full address *',
              hintText: 'Building, street, landmark',
              prefixIcon: Icon(Icons.home_work_outlined),
            ),
            onChanged: (s) {
              v.address = s;
              changed();
            },
            validator: (s) => (s ?? '').trim().length < 5 ? 'Enter the full address' : null,
          ),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextFormField(
                initialValue: v.area,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Area / locality', hintText: 'Indiranagar'),
                onChanged: (s) {
                  v.area = s;
                  changed();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                initialValue: v.city,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'City *', hintText: 'Bengaluru'),
                onChanged: (s) {
                  v.city = s;
                  changed();
                },
                validator: (s) => (s ?? '').trim().length < 2 ? 'Enter city' : null,
              ),
            ),
          ]),
          const SizedBox(height: 18),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                IconBubble(pinned ? Icons.location_on_rounded : Icons.location_off_outlined,
                    color: pinned ? AppColors.green : AppColors.text2, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(pinned ? 'Map pin set' : 'Map pin not set',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    Text(
                      pinned
                          ? '${v.latitude!.toStringAsFixed(5)}, ${v.longitude!.toStringAsFixed(5)}'
                          : 'Recommended — powers "near me" search',
                      style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                    ),
                  ]),
                ),
                if (pinned) const Tag('PINNED', color: AppColors.green, dense: true),
              ]),
              const SizedBox(height: 12),
              const Text('Stand at your venue entrance and tap below so members get accurate directions.',
                  style: TextStyle(color: AppColors.text2, fontSize: 13, height: 1.4)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: _locating
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.my_location_rounded, color: AppColors.primary),
                label: Text(pinned ? 'Update location' : 'Use my current location'),
                onPressed: _locating ? null : _useCurrentLocation,
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _UserMessage implements Exception {
  const _UserMessage(this.message);
  final String message;
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
      final t = await showTimePicker(
        context: context,
        initialTime: _parse(opening ? venue.opensAt : venue.closesAt),
        helpText: opening ? 'OPENS AT' : 'CLOSES AT',
      );
      if (t == null) return;
      opening ? venue.opensAt = _fmt(t) : venue.closesAt = _fmt(t);
      onChanged();
    }

    void setDays(Iterable<String> days) {
      venue.openDays = days.toList();
      onChanged();
    }

    final badRange = venue.closesAt.compareTo(venue.opensAt) <= 0;

    Widget timeCard(String label, IconData icon, String value, VoidCallback onTap) => Expanded(
          child: AppCard(
            onTap: onTap,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, size: 18, color: AppColors.primary),
                const SizedBox(width: 6),
                Text(label, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 10),
              Text(formatTimeOfDay('$value:00'),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
              const SizedBox(height: 2),
              const Text('Tap to change', style: TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w600)),
            ]),
          ),
        );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _StepIntro('When are you open?', 'Members can only check in during these hours.'),
        Row(children: [
          timeCard('Opens at', Icons.wb_sunny_rounded, venue.opensAt, () => pick(true)),
          const SizedBox(width: 12),
          timeCard('Closes at', Icons.nightlight_round, venue.closesAt, () => pick(false)),
        ]),
        if (badRange)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('Closing time must be after opening time',
                style: TextStyle(color: AppColors.red, fontWeight: FontWeight.w700, fontSize: 12.5)),
          ),
        const SectionTitle('Open on'),
        Row(children: [
          for (final d in _days.entries) ...[
            Expanded(
              child: Tap(
                onTap: () {
                  venue.openDays.contains(d.key) ? venue.openDays.remove(d.key) : venue.openDays.add(d.key);
                  onChanged();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: venue.openDays.contains(d.key) ? AppColors.primary : AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: venue.openDays.contains(d.key) ? AppColors.primary : AppColors.line),
                  ),
                  child: Text(d.value.substring(0, 2),
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: venue.openDays.contains(d.key) ? Colors.white : AppColors.text2)),
                ),
              ),
            ),
            if (d.key != 'sun') const SizedBox(width: 6),
          ],
        ]),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ActionChip(label: const Text('All 7 days'), onPressed: () => setDays(_days.keys)),
          ActionChip(label: const Text('Mon – Sat'), onPressed: () => setDays(_days.keys.take(6))),
          ActionChip(label: const Text('Weekdays'), onPressed: () => setDays(_days.keys.take(5))),
        ]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Step 5 — photos (P4: 4–5 photos)
// ---------------------------------------------------------------------------
class _PhotosStep extends StatefulWidget {
  const _PhotosStep({
    required this.venue,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onUploading,
  });

  final PartnerVenue venue;
  final int min;
  final int max;
  final VoidCallback onChanged;
  final ValueChanged<int> onUploading;

  @override
  State<_PhotosStep> createState() => _PhotosStepState();
}

class _PhotosStepState extends State<_PhotosStep> {
  final _picker = ImagePicker();

  /// Uploads in flight, keyed by a local id, with a preview of the picked bytes.
  final _uploading = <int, Uint8List?>{};
  int _nextId = 0;

  int get _remaining => widget.max - widget.venue.photos.length - _uploading.length;

  Future<void> _add(ImageSource source) async {
    try {
      final List<XFile> files;
      if (source == ImageSource.camera || _remaining == 1) {
        final f = await _picker.pickImage(source: source, maxWidth: 1600, imageQuality: 80);
        files = f == null ? [] : [f];
      } else {
        files = await _picker.pickMultiImage(maxWidth: 1600, imageQuality: 80, limit: _remaining);
      }
      if (!mounted) return;
      if (files.length > _remaining) {
        toast(context, 'Only $_remaining more photo${_remaining == 1 ? '' : 's'} can be added', icon: Icons.info_outline_rounded);
      }
      for (final f in files.take(_remaining)) {
        _upload(f);
      }
    } catch (_) {
      if (mounted) toast(context, 'Couldn\'t open photos. Check the app\'s permissions.', error: true);
    }
  }

  Future<void> _upload(XFile file) async {
    if (!mounted) return;
    final api = context.read<PartnerSession>().api;
    final id = _nextId++;
    setState(() => _uploading[id] = null);
    widget.onUploading(_uploading.length);
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length > 3 * 1024 * 1024) throw const _UserMessage('Each photo must be under 3 MB');
      if (mounted) setState(() => _uploading[id] = bytes);
      final url = await api.upload(file);
      widget.venue.photos.add(url);
      widget.onChanged();
    } catch (e) {
      if (mounted) toast(context, e is _UserMessage ? e.message : friendlyError(e), error: true);
    } finally {
      _uploading.remove(id);
      if (mounted) setState(() {});
      widget.onUploading(_uploading.length);
    }
  }

  void _pickSource() {
    showAppSheet<void>(
      context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Add photos', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            _SheetOption(
              icon: Icons.photo_library_rounded,
              title: 'Choose from gallery',
              subtitle: 'Pick up to $_remaining',
              onTap: () {
                Navigator.pop(ctx);
                _add(ImageSource.gallery);
              },
            ),
            const SizedBox(height: 10),
            _SheetOption(
              icon: Icons.photo_camera_rounded,
              title: 'Take a photo',
              subtitle: 'Use the camera now',
              onTap: () {
                Navigator.pop(ctx);
                _add(ImageSource.camera);
              },
            ),
          ]),
        ),
      ),
    );
  }

  void _move(int from, int to) {
    final photos = widget.venue.photos;
    if (to < 0 || to >= photos.length) return;
    setState(() => photos.insert(to, photos.removeAt(from)));
    widget.onChanged();
  }

  void _remove(int i) {
    setState(() => widget.venue.photos.removeAt(i));
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.venue.photos;
    final count = photos.length;
    final enough = count >= widget.min;
    final fallback = venueVisual(widget.venue.categories.firstOrNull ?? '').image;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StepIntro('Show off your space',
            'Add ${widget.min}–${widget.max} bright, clear photos: entrance, main floor, equipment, changing rooms. '
            'The first photo is your cover.'),
        AppCard(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            IconBubble(enough ? Icons.check_circle_rounded : Icons.photo_camera_back_rounded,
                color: enough ? AppColors.green : AppColors.amber, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$count of ${widget.max} photos', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (count / widget.max).clamp(0.0, 1.0),
                    minHeight: 6,
                    color: enough ? AppColors.green : AppColors.amber,
                    backgroundColor: AppColors.surfaceAlt,
                  ),
                ),
                const SizedBox(height: 6),
                Text(enough ? 'Ready to submit' : 'Add ${widget.min - count} more to submit for review',
                    style: const TextStyle(color: AppColors.text2, fontSize: 12)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.1,
          children: [
            for (var i = 0; i < photos.length; i++)
              ClipRRect(
                key: ValueKey(photos[i]),
                borderRadius: BorderRadius.circular(16),
                child: Stack(fit: StackFit.expand, children: [
                  NetImage(photos[i], fallback: fallback),
                  const PhotoScrim(strength: 0.55),
                  if (i == 0)
                    const Positioned(
                      left: 8,
                      top: 8,
                      child: Tag('COVER', icon: Icons.star_rounded, color: AppColors.primary, solid: true, dense: true),
                    ),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: _PhotoBtn(icon: Icons.close_rounded, tooltip: 'Remove', onTap: () => _remove(i)),
                  ),
                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 6,
                    child: Row(children: [
                      _PhotoBtn(
                        icon: Icons.chevron_left_rounded,
                        tooltip: 'Move earlier',
                        onTap: i == 0 ? null : () => _move(i, i - 1),
                      ),
                      const Spacer(),
                      if (i != 0)
                        Tap(
                          onTap: () => _move(i, 0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                            child: const Text('Set cover',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.ink)),
                          ),
                        ),
                      const Spacer(),
                      _PhotoBtn(
                        icon: Icons.chevron_right_rounded,
                        tooltip: 'Move later',
                        onTap: i == photos.length - 1 ? null : () => _move(i, i + 1),
                      ),
                    ]),
                  ),
                ]),
              ),
            for (final preview in _uploading.values)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(fit: StackFit.expand, children: [
                  if (preview != null)
                    Image.memory(preview, fit: BoxFit.cover)
                  else
                    const ColoredBox(color: AppColors.surfaceAlt),
                  ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
                  const Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.6, color: Colors.white)),
                      SizedBox(height: 8),
                      Text('Uploading…', style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ]),
              ),
            if (_remaining > 0)
              Tap(
                onTap: _pickSource,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.45), width: 1.5),
                    color: AppColors.primarySoft,
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const IconBubble(Icons.add_a_photo_rounded, color: AppColors.primary, bg: Colors.white, size: 48),
                    const SizedBox(height: 8),
                    const Text('Add photos', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800)),
                    Text('$_remaining slot${_remaining == 1 ? '' : 's'} left',
                        style: const TextStyle(color: AppColors.text2, fontSize: 11.5, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        const Text('Tips: shoot in daylight, landscape orientation, no people\'s faces without consent. Max 3 MB each.',
            style: TextStyle(color: AppColors.text3, fontSize: 12, height: 1.4)),
      ],
    );
  }
}

class _PhotoBtn extends StatelessWidget {
  const _PhotoBtn({required this.icon, required this.onTap, required this.tooltip});
  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Tap(
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.35 : 1,
          child: Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: Icon(icon, size: 18, color: AppColors.ink),
          ),
        ),
      ),
    );
  }
}

class _SheetOption extends StatelessWidget {
  const _SheetOption({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      border: true,
      shadow: false,
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        IconBubble(icon, size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            Text(subtitle, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
      ]),
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
    if (value.isEmpty) return;
    if (value.length > 80) {
      toast(context, 'Keep each item under 80 characters', error: true);
      return;
    }
    if (!widget.venue.equipment.any((e) => e.toLowerCase() == value.toLowerCase())) {
      setState(() => widget.venue.equipment.add(value));
      widget.onChanged();
    }
    _equipment.clear();
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
      padding: const EdgeInsets.all(16),
      children: [
        const _StepIntro('Facilities & features', 'Help members know what to expect.'),
        AppCard(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(children: [
            const IconBubble(Icons.sports_rounded, color: AppColors.teal, size: 42),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Trainer available', style: TextStyle(fontWeight: FontWeight.w800)),
                Text('A coach is on the floor to guide members', style: TextStyle(color: AppColors.text2, fontSize: 12.5)),
              ]),
            ),
            Switch(
              value: v.trainerAvailable,
              onChanged: (on) {
                setState(() => v.trainerAvailable = on);
                widget.onChanged();
              },
            ),
          ]),
        ),
        const SectionTitle('Amenities', subtitle: 'Tap everything you offer'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: amenityLabels.entries.map((a) {
            final selected = v.amenities.contains(a.key);
            return Tap(
              onTap: () {
                setState(() => selected ? v.amenities.remove(a.key) : v.amenities.add(a.key));
                widget.onChanged();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: selected ? AppColors.primarySoft : AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: selected ? AppColors.primary : AppColors.line, width: selected ? 1.5 : 1),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(selected ? Icons.check_rounded : a.value.$2,
                      size: 17, color: selected ? AppColors.primary : AppColors.text2),
                  const SizedBox(width: 6),
                  Text(a.value.$1,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: selected ? AppColors.primary : AppColors.text)),
                ]),
              ),
            );
          }).toList(),
        ),
        const SectionTitle('Equipment', subtitle: 'What members can use'),
        TextField(
          controller: _equipment,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: 'Add equipment, e.g. Leg press',
            prefixIcon: const Icon(Icons.fitness_center_rounded),
            suffixIcon: IconButton(
              icon: const Icon(Icons.add_circle_rounded, color: AppColors.primary),
              onPressed: () => _addEquipment(_equipment.text),
            ),
          ),
          onSubmitted: _addEquipment,
        ),
        if (v.equipment.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: v.equipment
                .map((e) => InputChip(
                      label: Text(e),
                      backgroundColor: AppColors.surfaceAlt,
                      side: BorderSide.none,
                      deleteIcon: const Icon(Icons.close_rounded, size: 16),
                      onDeleted: () {
                        setState(() => v.equipment.remove(e));
                        widget.onChanged();
                      },
                    ))
                .toList(),
          ),
        ],
        const SizedBox(height: 16),
        const Text('QUICK ADD', style: TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: _suggestions
              .where((s) => !v.equipment.contains(s))
              .map((s) => ActionChip(
                    avatar: const Icon(Icons.add_rounded, size: 16, color: AppColors.primary),
                    label: Text(s),
                    onPressed: () => _addEquipment(s),
                  ))
              .toList(),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Step 7 — review
// ---------------------------------------------------------------------------
class _ReviewStep extends StatelessWidget {
  const _ReviewStep({required this.venue, required this.minPhotos, required this.onEdit, required this.problems});

  final PartnerVenue venue;
  final int minPhotos;
  final ValueChanged<int> onEdit;
  final List<({int step, String message})> problems;

  @override
  Widget build(BuildContext context) {
    final v = venue;
    final visual = venueVisual(v.categories.firstOrNull ?? '');
    final location = [v.address, v.area, v.city].where((s) => s.trim().isNotEmpty).join(', ');
    final needPhotos = v.status.canSubmit && v.photos.length < minPhotos;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _StepIntro('Review your listing', 'This is how members will see you. Tap any section to change it.'),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              child: SizedBox(
                height: 160,
                child: Stack(fit: StackFit.expand, children: [
                  NetImage(v.photos.firstOrNull, fallback: visual.image),
                  const PhotoScrim(strength: 0.7),
                  if (v.id != null) Positioned(left: 12, top: 12, child: StatusPill(v.status, onPhoto: true)),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 12,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(v.name.trim().isEmpty ? 'Your venue name' : v.name.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                      if (location.isNotEmpty)
                        Text(location,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final c in v.categories) Tag(venueVisual(c).label, icon: venueVisual(c).icon, color: venueVisual(c).color),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        if (problems.isNotEmpty || needPhotos)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.amberSoft, borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Still to do', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF9A5B00))),
              const SizedBox(height: 6),
              for (final p in problems) _todo(p.message, () => onEdit(p.step)),
              if (needPhotos)
                _todo('Add ${minPhotos - v.photos.length} more photo${minPhotos - v.photos.length == 1 ? '' : 's'} '
                    'to submit (you can still save a draft)', () => onEdit(4)),
            ]),
          ),
        _section(0, Icons.category_rounded, AppColors.primary, 'Category',
            v.categories.isEmpty ? 'None selected' : v.categories.map((c) => venueVisual(c).label).join(', ')),
        _section(1, Icons.storefront_rounded, AppColors.blue, 'Details', [
          if (v.description.trim().isNotEmpty) v.description.trim() else 'No description',
          [v.contactPhone, v.contactEmail].where((s) => s.trim().isNotEmpty).join(' · '),
        ].where((s) => s.isNotEmpty).join('\n')),
        _section(2, Icons.place_rounded, AppColors.red, 'Location', [
          location.isEmpty ? 'No address' : location,
          v.latitude == null ? 'Map pin not set' : 'Map pin set',
        ].join('\n')),
        _section(3, Icons.schedule_rounded, AppColors.purple, 'Timings',
            '${formatTimeOfDay('${v.opensAt}:00')} – ${formatTimeOfDay('${v.closesAt}:00')} · ${v.openDays.length} days a week'),
        _section(4, Icons.photo_library_rounded, AppColors.teal, 'Photos', '${v.photos.length} uploaded'),
        _section(5, Icons.checklist_rounded, AppColors.green, 'Facilities', [
          v.trainerAvailable ? 'Trainer available' : 'No trainer',
          if (v.amenities.isNotEmpty) v.amenities.map((a) => amenityLabels[a]?.$1 ?? a).join(', '),
          if (v.equipment.isNotEmpty) '${v.equipment.length} equipment item${v.equipment.length == 1 ? '' : 's'}',
        ].join(' · ')),
        if (v.status.canSubmit) ...[
          const SizedBox(height: 6),
          const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.verified_rounded, size: 18, color: AppColors.green),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'After you submit, the FITKEY team verifies your listing (usually within 2 working days). '
                'You can keep editing while it\'s a draft.',
                style: TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.4),
              ),
            ),
          ]),
        ],
      ],
    );
  }

  Widget _todo(String text, VoidCallback onTap) => Tap(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            const Icon(Icons.radio_button_unchecked_rounded, size: 16, color: AppColors.amber),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(color: Color(0xFF9A5B00), fontWeight: FontWeight.w600))),
            const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.amber),
          ]),
        ),
      );

  Widget _section(int step, IconData icon, Color color, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AppCard(
          onTap: () => onEdit(step),
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconBubble(icon, color: color, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(body,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.text2, fontSize: 13, height: 1.4)),
              ]),
            ),
            const Text('Edit', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 13)),
          ]),
        ),
      );
}

class _StepIntro extends StatelessWidget {
  const _StepIntro(this.title, this.subtitle);

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18, top: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        const SizedBox(height: 6),
        Text(subtitle, style: const TextStyle(color: AppColors.text2, height: 1.4)),
      ]),
    );
  }
}
