// Per-type form state + the first three wizard steps (Profile · Pricing · Availability) for trainers, clinics,
// chemists and store sellers (Partner BRD §7). Field names follow the camelCased DB columns (migration 211).

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../data/brd_api.dart';
import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../vendor/vendor_portal_screen.dart';
import 'listing_fields.dart';

abstract class TypeForm extends ChangeNotifier {
  TypeForm(this.type);
  final PartnerType type;

  static TypeForm create(PartnerType t, PartnerUser? user) => switch (t) {
        PartnerType.trainer => TrainerForm(user),
        PartnerType.clinic => ClinicForm(user),
        PartnerType.chemist => ChemistForm(user),
        PartnerType.storeSeller => StoreForm(user),
        _ => throw ArgumentError('Venue types use VenueEditorScreen'),
      };

  void load(Json? l);
  Json toJson();
  String get displayName;
  String? get coverPhoto;

  List<String> get requiredDocs;
  List<String> get optionalDocs => const [];

  /// Extra copy shown on the documents step (verified badge, FSSAI rule…).
  String? get docsNote => null;

  String get profileTitle => 'Profile';
  String get pricingTitle => 'Pricing';
  String get availabilityTitle => 'Availability';

  Widget profileStep(BuildContext context);
  Widget pricingStep(BuildContext context);
  Widget availabilityStep(BuildContext context);

  /// (label, value) pairs for the review preview.
  List<(String, String)> reviewRows();

  /// Blocking problem before leaving [step] (0-based, only profile basics are blocking — the server checklist does
  /// the rest).
  String? blockingProblem(int step) => step == 0 && displayName.trim().length < 2 ? 'Enter a name first' : null;

  void changed() => notifyListeners();

  List<TextEditingController> get _controllers;

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }
}

TextField _text(
  TypeForm f,
  TextEditingController c,
  String label, {
  IconData? icon,
  int maxLines = 1,
  TextInputType? keyboard,
  String? helper,
  int? maxLength,
}) =>
    TextField(
      controller: c,
      maxLines: maxLines,
      minLines: 1,
      maxLength: maxLength,
      keyboardType: keyboard ?? (maxLines > 1 ? TextInputType.multiline : TextInputType.text),
      textCapitalization: TextCapitalization.sentences,
      onChanged: (_) => f.changed(),
      decoration: InputDecoration(labelText: label, helperText: helper, prefixIcon: icon == null ? null : Icon(icon)),
    );

const _gap = SizedBox(height: 12);

// =================================================================================================================
// Trainer
// =================================================================================================================

const trainerSubtypes = {
  'physiotherapist': 'Physiotherapist',
  'yoga_master': 'Yoga master',
  'gym_trainer_gym': 'Gym trainer (at gym)',
  'gym_trainer_home': 'Gym trainer (at home)',
  'sports_coach': 'Sports coach',
  'boxing': 'Boxing',
  'karate': 'Karate',
  'mma': 'MMA',
  'dance': 'Dance',
  'nutritionist': 'Nutritionist',
};

const trainerModes = {'online': 'Online', 'home': 'At home', 'gym': 'At gym'};

class TrainerPackageRow {
  TrainerPackageRow(Json j)
      : name = TextEditingController(text: '${j['name'] ?? ''}'),
        sessions = TextEditingController(text: intOf(j['sessions']) == 0 ? '' : '${intOf(j['sessions'])}'),
        price = TextEditingController(text: rupeesText(j['pricePaise']));
  final TextEditingController name;
  final TextEditingController sessions;
  final TextEditingController price;

  Json toJson() => {'name': name.text.trim(), 'sessions': int.tryParse(sessions.text) ?? 0, 'pricePaise': paiseOf(price.text)};
  bool get empty => name.text.trim().isEmpty && price.text.trim().isEmpty;
  List<TextEditingController> get all => [name, sessions, price];
}

class TrainerForm extends TypeForm {
  TrainerForm(PartnerUser? user) : super(PartnerType.trainer) {
    name.text = user?.name ?? '';
  }

  final name = TextEditingController();
  final bio = TextEditingController();
  final experience = TextEditingController();
  final serviceArea = TextEditingController();
  final rate = TextEditingController();
  final maxPerDay = TextEditingController();
  String? photoUrl;
  Set<String> subtypes = {};
  List<String> achievements = [];
  List<String> languages = [];
  Set<String> modes = {'gym'};
  final List<TrainerPackageRow> packages = [];
  List<TimeWindow> slots = [];
  bool certificatesVerified = false;
  final List<TextEditingController> _removed = [];

  @override
  List<TextEditingController> get _controllers =>
      [name, bio, experience, serviceArea, rate, maxPerDay, for (final p in packages) ...p.all, ..._removed];

  @override
  void load(Json? l) {
    if (l == null) return;
    name.text = '${l['name'] ?? name.text}';
    bio.text = '${l['bio'] ?? ''}';
    experience.text = intOf(l['experienceYears']) == 0 ? '' : '${intOf(l['experienceYears'])}';
    serviceArea.text = '${l['serviceArea'] ?? ''}';
    rate.text = rupeesText(l['hourlyRatePaise'] ?? l['pricePaise']);
    maxPerDay.text = intOf(l['maxSessionsPerDay']) == 0 ? '' : '${intOf(l['maxSessionsPerDay'])}';
    photoUrl = l['photoUrl'];
    subtypes = {...strList(l['subtypes'])}..retainWhere(trainerSubtypes.containsKey);
    achievements = strList(l['achievements']);
    languages = strList(l['languages']);
    final m = strList(l['trainingModes'] ?? l['modes']);
    if (m.isNotEmpty) modes = {...m}..retainWhere(trainerModes.containsKey);
    packages.addAll([for (final p in (l['packages'] as List? ?? const [])) TrainerPackageRow(p as Json)]);
    slots = [for (final s in (l['weeklySlots'] as List? ?? const [])) TimeWindow.fromJson(s as Json)];
    certificatesVerified = l['verifiedBadge'] == true || l['certificatesVerifiedAt'] != null;
  }

  @override
  Json toJson() => {
        'name': name.text.trim(),
        'bio': bio.text.trim(),
        'photoUrl': photoUrl,
        'subtypes': subtypes.toList(),
        'experienceYears': int.tryParse(experience.text) ?? 0,
        'achievements': achievements,
        'languages': languages,
        'trainingModes': modes.toList(),
        'serviceArea': serviceArea.text.trim(),
        'hourlyRatePaise': paiseOf(rate.text),
        'packages': [for (final p in packages) if (!p.empty) p.toJson()],
        'weeklySlots': [for (final s in slots) s.toJson()],
        'maxSessionsPerDay': int.tryParse(maxPerDay.text),
      };

  @override
  String get displayName => name.text;
  @override
  String? get coverPhoto => photoUrl;
  @override
  List<String> get requiredDocs => const ['certificate'];
  @override
  List<String> get optionalDocs => const ['achievement'];
  @override
  String? get docsNote => certificatesVerified
      ? 'Your certificates are verified — the Verified badge shows on your profile.'
      : 'Verified badge appears after our team checks your certificates.';
  @override
  String get availabilityTitle => 'Slots';

  @override
  Widget profileStep(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FieldSection(
          title: 'About you',
          icon: Icons.person_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SinglePhotoField(url: photoUrl, label: 'Profile photo', onChanged: (u) {
              photoUrl = u;
              changed();
            }),
            _gap,
            _text(this, name, 'Full name', icon: Icons.badge_rounded),
            _gap,
            _text(this, experience, 'Experience (years)', icon: Icons.timeline_rounded, keyboard: TextInputType.number),
            _gap,
            _text(this, bio, 'Short bio', icon: Icons.notes_rounded, maxLines: 4, maxLength: 600),
          ]),
        ),
        FieldSection(
          title: 'What do you teach?',
          subtitle: 'Pick all that apply.',
          icon: Icons.sports_gymnastics_rounded,
          child: MultiSelectChips(
            options: trainerSubtypes,
            selected: subtypes,
            onChanged: (s) {
              subtypes = s;
              changed();
            },
          ),
        ),
        FieldSection(
          title: 'Achievements',
          subtitle: 'Titles, medals, notable clients — add proof on the Documents step.',
          icon: Icons.emoji_events_rounded,
          child: TagInput(
            values: achievements,
            hint: 'e.g. State boxing champion 2022',
            onChanged: (v) {
              achievements = v;
              changed();
            },
          ),
        ),
        FieldSection(
          title: 'Languages',
          icon: Icons.translate_rounded,
          child: TagInput(
            values: languages,
            hint: 'Add a language',
            suggestions: const ['Hindi', 'English', 'Marathi', 'Tamil', 'Telugu', 'Kannada', 'Bengali', 'Gujarati'],
            onChanged: (v) {
              languages = v;
              changed();
            },
          ),
        ),
        FieldSection(
          title: 'Where do you train?',
          icon: Icons.place_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MultiSelectChips(
              options: trainerModes,
              selected: modes,
              onChanged: (s) {
                modes = s;
                changed();
              },
            ),
            _gap,
            _text(this, serviceArea, 'Service area', icon: Icons.map_rounded, helper: 'e.g. Andheri, Bandra, Juhu (within 8 km)'),
          ]),
        ),
      ]);

  @override
  Widget pricingStep(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FieldSection(
          title: 'Session price',
          subtitle: 'Price for one session (up to an hour). Include GST.',
          icon: Icons.payments_rounded,
          child: TextField(
            controller: rate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: decimalOnly,
            onChanged: (_) => changed(),
            decoration: moneyDecoration('Price per hour / session', helper: 'Minimum ₹100'),
          ),
        ),
        FieldSection(
          title: 'Packages',
          subtitle: 'Optional bundles, e.g. "12 sessions — ₹9,000".',
          icon: Icons.inventory_2_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final p in packages)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
                  child: Column(children: [
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: p.name,
                          onChanged: (_) => changed(),
                          decoration: const InputDecoration(labelText: 'Package name'),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red),
                        onPressed: () {
                          packages.remove(p);
                          _removed.addAll(p.all);
                          changed();
                        },
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: p.sessions,
                          keyboardType: TextInputType.number,
                          inputFormatters: digitsOnly,
                          onChanged: (_) => changed(),
                          decoration: const InputDecoration(labelText: 'Sessions'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: p.price,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: decimalOnly,
                          onChanged: (_) => changed(),
                          decoration: const InputDecoration(labelText: 'Price', prefixText: '₹ '),
                        ),
                      ),
                    ]),
                  ]),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () {
                  packages.add(TrainerPackageRow(const {}));
                  changed();
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add package'),
              ),
            ),
          ]),
        ),
      ]);

  @override
  Widget availabilityStep(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FieldSection(
          title: 'Weekly slots',
          subtitle: 'When members can book you. Add several windows a day if you like.',
          icon: Icons.event_available_rounded,
          child: TimeWindowsEditor(
            windows: slots,
            addLabel: 'Add slots',
            onChanged: (w) {
              slots = w;
              changed();
            },
          ),
        ),
        FieldSection(
          title: 'Daily limit',
          icon: Icons.speed_rounded,
          child: _text(this, maxPerDay, 'Max sessions per day',
              icon: Icons.format_list_numbered_rounded, keyboard: TextInputType.number),
        ),
      ]);

  @override
  List<(String, String)> reviewRows() => [
        ('Teaches', subtypes.map((s) => trainerSubtypes[s]).join(', ')),
        ('Experience', experience.text.isEmpty ? '' : '${experience.text} years'),
        ('Modes', modes.map((m) => trainerModes[m]).join(' · ')),
        ('Service area', serviceArea.text),
        ('Languages', languages.join(', ')),
        ('Price', rate.text.isEmpty ? '' : '₹${rate.text} / session'),
        ('Packages', '${packages.where((p) => !p.empty).length}'),
        ('Weekly slots', '${slots.length} windows'),
        ('Max / day', maxPerDay.text),
      ];
}

// =================================================================================================================
// Location pin (clinic / chemist)
// =================================================================================================================

class _LocationPin extends StatefulWidget {
  const _LocationPin({required this.lat, required this.lng, required this.onChanged});
  final double? lat;
  final double? lng;
  final void Function(double? lat, double? lng) onChanged;

  @override
  State<_LocationPin> createState() => _LocationPinState();
}

class _LocationPinState extends State<_LocationPin> {
  bool _busy = false;

  Future<void> _locate() async {
    setState(() => _busy = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw 'Turn on location services';
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) throw 'Location permission denied';
      final pos = await Geolocator.getCurrentPosition();
      widget.onChanged(pos.latitude, pos.longitude);
    } catch (e) {
      if (mounted) toast(context, e is String ? e : 'Could not get your location', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final has = widget.lat != null && widget.lng != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(has ? Icons.location_on_rounded : Icons.location_searching_rounded,
            color: has ? AppColors.green : AppColors.text3),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            has
                ? 'Map pin set (${widget.lat!.toStringAsFixed(5)}, ${widget.lng!.toStringAsFixed(5)})'
                : 'Map pin (optional) — stand at the entrance and tap "Use my location".',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ),
        if (has)
          IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => widget.onChanged(null, null)),
        TextButton(
          onPressed: _busy ? null : _locate,
          child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(has ? 'Update' : 'Use my location'),
        ),
      ]),
    );
  }
}

// =================================================================================================================
// Clinic
// =================================================================================================================

const clinicSpecialities = [
  'Physiotherapy',
  'Orthopaedics',
  'Sports medicine',
  'General physician',
  'Dermatology',
  'Dietetics',
  'Cardiology',
  'Dental',
];

class DoctorRow {
  DoctorRow(Json j)
      : name = TextEditingController(text: '${j['name'] ?? ''}'),
        qualification = TextEditingController(text: '${j['degree'] ?? j['qualification'] ?? ''}'),
        registrationNo = TextEditingController(text: '${j['registrationNo'] ?? ''}');
  final TextEditingController name;
  final TextEditingController qualification;
  final TextEditingController registrationNo;

  Json toJson() =>
      {'name': name.text.trim(), 'degree': qualification.text.trim(), 'registrationNo': registrationNo.text.trim()};
  bool get empty => name.text.trim().isEmpty;
  List<TextEditingController> get all => [name, qualification, registrationNo];
}

class ClinicForm extends TypeForm {
  ClinicForm(PartnerUser? user) : super(PartnerType.clinic) {
    city.text = user?.city ?? '';
  }

  final name = TextEditingController();
  final speciality = TextEditingController();
  final address = TextEditingController();
  final area = TextEditingController();
  final city = TextEditingController();
  final fee = TextEditingController();
  final List<DoctorRow> doctors = [];
  final List<TextEditingController> _removed = [];
  List<String> photos = [];
  List<TimeWindow> opd = [];
  int slotMinutes = 15;
  double? lat;
  double? lng;

  @override
  List<TextEditingController> get _controllers =>
      [name, speciality, address, area, city, fee, for (final d in doctors) ...d.all, ..._removed];

  @override
  void load(Json? l) {
    if (l == null) {
      doctors.add(DoctorRow(const {}));
      return;
    }
    name.text = '${l['name'] ?? ''}';
    speciality.text = '${l['speciality'] ?? ''}';
    address.text = '${l['address'] ?? ''}';
    area.text = '${l['area'] ?? ''}';
    city.text = '${l['city'] ?? city.text}';
    fee.text = rupeesText(l['consultationFeePaise']);
    doctors.addAll([for (final d in (l['doctors'] as List? ?? const [])) if (d is Map) DoctorRow(Json.from(d))]);
    if (doctors.isEmpty) doctors.add(DoctorRow(const {}));
    photos = strList(l['photos']);
    opd = [for (final s in (l['opdHours'] as List? ?? const [])) TimeWindow.fromJson(s as Json)];
    slotMinutes = intOf(l['slotMinutes']) == 0 ? 15 : intOf(l['slotMinutes']);
    lat = doubleOf(l['latitude']);
    lng = doubleOf(l['longitude']);
  }

  @override
  Json toJson() => {
        'name': name.text.trim(),
        'speciality': speciality.text.trim(),
        'doctors': [for (final d in doctors) if (!d.empty) d.toJson()],
        'address': address.text.trim(),
        'area': area.text.trim(),
        'city': city.text.trim(),
        'latitude': lat,
        'longitude': lng,
        'photos': photos,
        'consultationFeePaise': paiseOf(fee.text),
        'opdHours': [for (final w in opd) w.toJson(opensCloses: true)],
        'slotMinutes': slotMinutes,
      };

  @override
  String get displayName => name.text;
  @override
  String? get coverPhoto => photos.firstOrNull;
  @override
  List<String> get requiredDocs => const ['clinic_registration', 'doctor_registration'];
  @override
  String? get docsNote => 'Upload the registration of every doctor listed on your profile.';
  @override
  String get profileTitle => 'Clinic';
  @override
  String get pricingTitle => 'Fees';
  @override
  String get availabilityTitle => 'OPD hours';

  @override
  Widget profileStep(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FieldSection(
          title: 'Clinic details',
          icon: Icons.local_hospital_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _text(this, name, 'Clinic name', icon: Icons.storefront_rounded),
            _gap,
            _text(this, speciality, 'Speciality', icon: Icons.medical_services_rounded),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in clinicSpecialities)
                ChoiceChip(
                  label: Text(s, style: const TextStyle(fontSize: 12.5)),
                  selected: speciality.text == s,
                  onSelected: (_) {
                    speciality.text = s;
                    changed();
                  },
                ),
            ]),
          ]),
        ),
        FieldSection(
          title: 'Doctors',
          subtitle: 'Members see each doctor\'s name and qualification.',
          icon: Icons.medical_information_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, d) in doctors.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(
                        child: Text('Doctor ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      if (doctors.length > 1)
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red),
                          onPressed: () {
                            doctors.remove(d);
                            _removed.addAll(d.all);
                            changed();
                          },
                        ),
                    ]),
                    TextField(
                      controller: d.name,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) => changed(),
                      decoration: const InputDecoration(labelText: 'Name', prefixText: 'Dr. '),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: d.qualification,
                      onChanged: (_) => changed(),
                      decoration: const InputDecoration(labelText: 'Qualification', hintText: 'MBBS, MD (Sports Medicine)'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: d.registrationNo,
                      textCapitalization: TextCapitalization.characters,
                      onChanged: (_) => changed(),
                      decoration: const InputDecoration(labelText: 'Medical council registration no.'),
                    ),
                  ]),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () {
                  doctors.add(DoctorRow(const {}));
                  changed();
                },
                icon: const Icon(Icons.person_add_rounded),
                label: const Text('Add doctor'),
              ),
            ),
          ]),
        ),
        FieldSection(
          title: 'Address',
          icon: Icons.place_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _text(this, address, 'Street address', icon: Icons.home_work_rounded, maxLines: 2),
            _gap,
            Row(children: [
              Expanded(child: _text(this, area, 'Area')),
              const SizedBox(width: 10),
              Expanded(child: _text(this, city, 'City')),
            ]),
            _gap,
            _LocationPin(lat: lat, lng: lng, onChanged: (a, b) {
              lat = a;
              lng = b;
              changed();
            }),
          ]),
        ),
        FieldSection(
          title: 'Photos',
          subtitle: 'Reception, consultation room, equipment. First photo is the cover.',
          icon: Icons.photo_library_rounded,
          child: PhotoGridField(urls: photos, onChanged: (u) {
            photos = u;
            changed();
          }),
        ),
      ]);

  @override
  Widget pricingStep(BuildContext context) => FieldSection(
        title: 'Consultation fee',
        subtitle: 'What a member pays per consultation (include GST if applicable).',
        icon: Icons.payments_rounded,
        child: TextField(
          controller: fee,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: decimalOnly,
          onChanged: (_) => changed(),
          decoration: moneyDecoration('Consultation fee'),
        ),
      );

  @override
  Widget availabilityStep(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FieldSection(
          title: 'OPD days & hours',
          subtitle: 'Add morning and evening OPD as separate windows.',
          icon: Icons.schedule_rounded,
          child: TimeWindowsEditor(
            windows: opd,
            addLabel: 'Add OPD window',
            onChanged: (w) {
              opd = w;
              changed();
            },
          ),
        ),
        FieldSection(
          title: 'Appointment slot length',
          icon: Icons.timer_rounded,
          child: Wrap(spacing: 8, children: [
            for (final m in const [10, 15, 20, 30, 45, 60])
              ChoiceChip(
                label: Text('$m min'),
                selected: slotMinutes == m,
                onSelected: (_) {
                  slotMinutes = m;
                  changed();
                },
              ),
          ]),
        ),
      ]);

  @override
  List<(String, String)> reviewRows() => [
        ('Speciality', speciality.text),
        ('Doctors', doctors.where((d) => !d.empty).map((d) => 'Dr. ${d.name.text.trim()}').join(', ')),
        ('Address', [address.text, area.text, city.text].where((s) => s.trim().isNotEmpty).join(', ')),
        ('Photos', '${photos.length}'),
        ('Consultation', fee.text.isEmpty ? '' : '₹${fee.text}'),
        ('OPD', '${opd.length} windows · $slotMinutes-min slots'),
      ];
}

// =================================================================================================================
// Chemist
// =================================================================================================================

class ChemistForm extends TypeForm {
  ChemistForm(PartnerUser? user) : super(PartnerType.chemist) {
    city.text = user?.city ?? '';
  }

  final name = TextEditingController();
  final address = TextEditingController();
  final area = TextEditingController();
  final city = TextEditingController();
  final radius = TextEditingController();
  final discount = TextEditingController();
  List<String> photos = [];
  List<TimeWindow> hours = [];
  bool delivery = true;
  double? lat;
  double? lng;

  @override
  List<TextEditingController> get _controllers => [name, address, area, city, radius, discount];

  @override
  void load(Json? l) {
    if (l == null) return;
    name.text = '${l['name'] ?? ''}';
    address.text = '${l['address'] ?? ''}';
    area.text = '${l['area'] ?? ''}';
    city.text = '${l['city'] ?? city.text}';
    final r = doubleOf(l['deliveryRadiusKm']);
    radius.text = r == null ? '' : (r == r.roundToDouble() ? '${r.toInt()}' : '$r');
    discount.text = intOf(l['discountPct']) == 0 ? '' : '${intOf(l['discountPct'])}';
    photos = strList(l['photos']);
    hours = [for (final s in (l['openHours'] as List? ?? const [])) TimeWindow.fromJson(s as Json)];
    delivery = (l['homeDelivery'] ?? l['deliveryAvailable']) != false;
    lat = doubleOf(l['latitude']);
    lng = doubleOf(l['longitude']);
  }

  @override
  Json toJson() => {
        'name': name.text.trim(),
        'address': address.text.trim(),
        'area': area.text.trim(),
        'city': city.text.trim(),
        'latitude': lat,
        'longitude': lng,
        'photos': photos,
        'deliveryRadiusKm': double.tryParse(radius.text),
        'discountPct': int.tryParse(discount.text) ?? 0,
        'openHours': [for (final w in hours) w.toJson(opensCloses: true)],
        'homeDelivery': delivery,
      };

  @override
  String get displayName => name.text;
  @override
  String? get coverPhoto => photos.firstOrNull;
  @override
  List<String> get requiredDocs => const ['drug_licence', 'gst'];
  @override
  String get profileTitle => 'Store';
  @override
  String get pricingTitle => 'Discount';
  @override
  String get availabilityTitle => 'Hours';

  @override
  Widget profileStep(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FieldSection(
          title: 'Pharmacy details',
          icon: Icons.local_pharmacy_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _text(this, name, 'Store name', icon: Icons.storefront_rounded),
            _gap,
            _text(this, address, 'Street address', icon: Icons.home_work_rounded, maxLines: 2),
            _gap,
            Row(children: [
              Expanded(child: _text(this, area, 'Area')),
              const SizedBox(width: 10),
              Expanded(child: _text(this, city, 'City')),
            ]),
            _gap,
            _LocationPin(lat: lat, lng: lng, onChanged: (a, b) {
              lat = a;
              lng = b;
              changed();
            }),
          ]),
        ),
        FieldSection(
          title: 'Photos',
          subtitle: 'Store front with the signboard, and the counter.',
          icon: Icons.photo_library_rounded,
          child: PhotoGridField(urls: photos, onChanged: (u) {
            photos = u;
            changed();
          }),
        ),
        FieldSection(
          title: 'Delivery radius',
          icon: Icons.delivery_dining_rounded,
          child: TextField(
            controller: radius,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: decimalOnly,
            onChanged: (_) => changed(),
            decoration: const InputDecoration(labelText: 'Deliver within', suffixText: 'km', prefixIcon: Icon(Icons.radar_rounded)),
          ),
        ),
      ]);

  @override
  Widget pricingStep(BuildContext context) {
    final pct = int.tryParse(discount.text) ?? 0;
    return FieldSection(
      title: 'Discount on MRP',
      subtitle: 'FitKey members get this discount on every order.',
      icon: Icons.percent_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: discount,
          keyboardType: TextInputType.number,
          inputFormatters: digitsOnly,
          maxLength: 2,
          onChanged: (_) => changed(),
          decoration: const InputDecoration(
              labelText: 'Discount', suffixText: '%', prefixIcon: Icon(Icons.local_offer_rounded), counterText: ''),
        ),
        if (pct > 0) ...[
          const SizedBox(height: 8),
          InfoNote('A ₹500 MRP order costs the member ₹${(500 * (100 - pct) / 100).toStringAsFixed(0)}.',
              icon: Icons.calculate_rounded, color: AppColors.green),
        ],
      ]),
    );
  }

  @override
  Widget availabilityStep(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FieldSection(
          title: 'Open hours',
          icon: Icons.schedule_rounded,
          child: TimeWindowsEditor(
            windows: hours,
            addLabel: 'Add hours',
            onChanged: (w) {
              hours = w;
              changed();
            },
          ),
        ),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: SwitchListTile(
            value: delivery,
            onChanged: (v) {
              delivery = v;
              changed();
            },
            title: const Text('Home delivery', style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text(delivery ? 'Members can order for delivery' : 'Store pickup only'),
          ),
        ),
      ]);

  @override
  List<(String, String)> reviewRows() => [
        ('Address', [address.text, area.text, city.text].where((s) => s.trim().isNotEmpty).join(', ')),
        ('Photos', '${photos.length}'),
        ('Discount', discount.text.isEmpty ? '' : '${discount.text}% on MRP'),
        ('Hours', '${hours.length} windows'),
        ('Delivery', delivery ? 'Yes${radius.text.isEmpty ? '' : ' · within ${radius.text} km'}' : 'No'),
      ];
}

// =================================================================================================================
// Store seller
// =================================================================================================================

const storeCategories = {
  'supplements': 'Supplements',
  'activewear': 'Activewear',
  'gym_gear': 'Gym gear',
  'healthy_food': 'Healthy food',
  'wellness': 'Wellness',
  'accessories': 'Accessories',
};

class StoreForm extends TypeForm {
  StoreForm(PartnerUser? user) : super(PartnerType.storeSeller);

  final brand = TextEditingController();
  final about = TextEditingController();
  final dispatch = TextEditingController();
  String? logoUrl;
  Set<String> categories = {};

  bool get needsFssai => categories.contains('supplements') || categories.contains('healthy_food');

  @override
  List<TextEditingController> get _controllers => [brand, about, dispatch];

  @override
  void load(Json? l) {
    if (l == null) return;
    brand.text = '${l['brandName'] ?? l['businessName'] ?? ''}';
    about.text = '${l['about'] ?? ''}';
    dispatch.text = l['dispatchDays'] == null ? '' : '${intOf(l['dispatchDays'])}';
    logoUrl = l['logoUrl'];
    categories = {...strList(l['categories'])}..retainWhere(storeCategories.containsKey);
  }

  @override
  Json toJson() => {
        'brandName': brand.text.trim(),
        'businessName': brand.text.trim(),
        'logoUrl': logoUrl,
        'about': about.text.trim(),
        'categories': categories.toList(),
        'dispatchDays': int.tryParse(dispatch.text),
      };

  @override
  String get displayName => brand.text;
  @override
  String? get coverPhoto => logoUrl;
  @override
  List<String> get requiredDocs => ['gst', 'trademark', if (needsFssai) 'fssai'];
  @override
  List<String> get optionalDocs => [if (!needsFssai) 'fssai'];
  @override
  String? get docsNote => needsFssai ? 'Supplements and food products cannot go live without a valid FSSAI licence.' : null;
  @override
  String get profileTitle => 'Brand';
  @override
  String get availabilityTitle => 'Stock';

  @override
  Widget profileStep(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FieldSection(
          title: 'Your brand',
          icon: Icons.storefront_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SinglePhotoField(url: logoUrl, label: 'Brand logo', round: false, onChanged: (u) {
              logoUrl = u;
              changed();
            }),
            _gap,
            _text(this, brand, 'Brand name', icon: Icons.sell_rounded),
            _gap,
            _text(this, about, 'About the brand', icon: Icons.notes_rounded, maxLines: 4, maxLength: 2000),
          ]),
        ),
        FieldSection(
          title: 'What do you sell?',
          icon: Icons.category_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MultiSelectChips(
              options: storeCategories,
              selected: categories,
              onChanged: (s) {
                categories = s;
                changed();
              },
            ),
            if (needsFssai) ...[
              _gap,
              const InfoNote('Supplements and food products cannot go live without a valid FSSAI licence.',
                  icon: Icons.warning_amber_rounded, color: AppColors.amber),
            ],
          ]),
        ),
      ]);

  @override
  Widget pricingStep(BuildContext context) => FieldSection(
        title: 'Prices per product',
        subtitle: 'You set the price and MRP of every SKU in your products list.',
        icon: Icons.sell_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const InfoNote('Pricing is managed per SKU in Products. Prices include GST.', icon: Icons.info_rounded),
          _gap,
          OutlinedButton.icon(
            onPressed: () => push(context, const VendorPortalScreen()),
            icon: const Icon(Icons.inventory_2_rounded),
            label: const Text('Open products & prices'),
          ),
        ]),
      );

  @override
  Widget availabilityStep(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FieldSection(
          title: 'Dispatch time',
          subtitle: 'Days between an order and handing it to the courier.',
          icon: Icons.local_shipping_rounded,
          child: TextField(
            controller: dispatch,
            keyboardType: TextInputType.number,
            inputFormatters: digitsOnly,
            maxLength: 2,
            onChanged: (_) => changed(),
            decoration: const InputDecoration(
                labelText: 'Dispatch within', suffixText: 'days', prefixIcon: Icon(Icons.timer_rounded), counterText: ''),
          ),
        ),
        const FieldSection(title: 'Stock per SKU', icon: Icons.inventory_rounded, child: _StockList()),
      ]);

  @override
  List<(String, String)> reviewRows() => [
        ('Categories', categories.map((c) => storeCategories[c]).join(', ')),
        ('About', about.text.length > 80 ? '${about.text.substring(0, 80)}…' : about.text),
        ('Dispatch', dispatch.text.isEmpty ? '' : 'within ${dispatch.text} days'),
        ('FSSAI', needsFssai ? 'Required' : 'Not required'),
      ];
}

class _StockList extends StatefulWidget {
  const _StockList();

  @override
  State<_StockList> createState() => _StockListState();
}

class _StockListState extends State<_StockList> {
  late Future<List<VendorProduct>> _f = context.read<PartnerSession>().api.vendorProducts();

  @override
  Widget build(BuildContext context) => FutureBuilder<List<VendorProduct>>(
        future: _f,
        builder: (context, snap) {
          final open = OutlinedButton.icon(
            onPressed: () async {
              await push(context, const VendorPortalScreen());
              if (mounted) setState(() => _f = context.read<PartnerSession>().api.vendorProducts());
            },
            icon: const Icon(Icons.edit_rounded),
            label: const Text('Manage products & stock'),
          );
          if (snap.connectionState != ConnectionState.done) return const SkeletonBox(height: 60);
          final items = snap.data ?? const <VendorProduct>[];
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (snap.hasError || items.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text('No products yet — add your SKUs with price and stock.',
                    style: TextStyle(color: AppColors.text3)),
              )
            else
              for (final p in items.take(8))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(
                      child: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Tag(
                      p.stockQuantity <= 0 ? 'SOLD OUT' : '${p.stockQuantity} in stock',
                      dense: true,
                      color: p.stockQuantity <= 0
                          ? AppColors.red
                          : (p.stockQuantity <= 10 ? AppColors.amber : AppColors.green),
                    ),
                  ]),
                ),
            if (items.length > 8)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('+${items.length - 8} more', style: const TextStyle(color: AppColors.text3)),
              ),
            open,
          ]);
        },
      );
}
