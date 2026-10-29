part of 'partner_trainer_screen.dart';

const _maxTypes = 12;

/// Suggested specialization tags (free text is allowed too).
const _specSuggestions = [
  'Strength training',
  'Fat loss',
  'Hypertrophy',
  'Mobility',
  'Injury rehab',
  'Pre/post natal',
  'Senior fitness',
  'Sports performance',
  'Nutrition coaching',
  'Beginners',
];

class _ProfileTab extends StatefulWidget {
  const _ProfileTab({required this.profile, required this.onReload, required this.onSaved});
  final Future<TrainerProfileDetails?> profile;
  final Future<void> Function() onReload;
  final ValueChanged<TrainerProfileDetails> onSaved;

  @override
  State<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<_ProfileTab> with AutomaticKeepAliveClientMixin {
  late Future<List<TrainerTypeGroup>> _types = context.read<PartnerSession>().api.trainerTypeCatalogue();

  @override
  bool get wantKeepAlive => true;

  Future<void> _retry() async {
    setState(() => _types = context.read<PartnerSession>().api.trainerTypeCatalogue());
    await widget.onReload();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<TrainerProfileDetails?>(
      future: widget.profile,
      builder: (context, pSnap) => FutureBuilder<List<TrainerTypeGroup>>(
        future: _types,
        builder: (context, tSnap) {
          if (pSnap.connectionState != ConnectionState.done || tSnap.connectionState != ConnectionState.done) {
            return const SkeletonList(count: 5, itemHeight: 90);
          }
          final error = pSnap.error ?? tSnap.error;
          if (error != null) return _RefreshableFill(onRefresh: _retry, child: ErrorView(error: error, onRetry: _retry));
          return _ProfileForm(
            key: ValueKey(pSnap.data?.profile.id ?? 'new'),
            details: pSnap.data,
            groups: tSnap.data!,
            onSaved: widget.onSaved,
          );
        },
      ),
    );
  }
}

class _ProfileForm extends StatefulWidget {
  const _ProfileForm({super.key, required this.details, required this.groups, required this.onSaved});
  final TrainerProfileDetails? details;
  final List<TrainerTypeGroup> groups;
  final ValueChanged<TrainerProfileDetails> onSaved;

  @override
  State<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<_ProfileForm> {
  final _form = GlobalKey<FormState>();
  late final PartnerTrainerProfile? _p = widget.details?.profile;
  late final _name = TextEditingController(text: _p?.name ?? context.read<PartnerSession>().user?.name ?? '');
  late final _bio = TextEditingController(text: _p?.bio ?? '');
  late final _rate = TextEditingController(text: _p == null || _p.hourlyRatePaise == 0 ? '' : '${_p.hourlyRatePaise ~/ 100}');
  late final _buffer = TextEditingController(text: '${_p?.bufferMinutes ?? 30}');
  final _certInput = TextEditingController();
  final _specInput = TextEditingController();

  late String? _photoUrl = _p?.photoUrl;
  late final List<String> _certs = [...?_p?.certifications];
  late final List<String> _specs = [...?_p?.specializations];
  late final Set<String> _modes = {...?_p?.trainingModes};
  // Only keys the catalogue still knows (the API rejects unknown ones).
  late final Set<String> _types = {...?widget.details?.trainerTypes}
    ..retainWhere((k) => widget.groups.any((g) => g.types.any((t) => t.key == k)));
  late TimeOfDay _start = _parseHm(widget.details?.workingStart ?? '06:00');
  late TimeOfDay _end = _parseHm(widget.details?.workingEnd ?? '21:00');

  bool _uploading = false;
  bool _busy = false;

  static TimeOfDay _parseHm(String s) {
    final parts = s.split(':');
    return TimeOfDay(hour: int.tryParse(parts.first) ?? 6, minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
  }

  static String _hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    for (final c in [_name, _bio, _rate, _buffer, _certInput, _specInput]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final XFile? f;
    try {
      f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1200, imageQuality: 85);
    } catch (_) {
      if (mounted) toast(context, 'Could not open your photos', error: true);
      return;
    }
    if (f == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final url = await context.read<PartnerSession>().api.uploadPicked(f);
      if (mounted) setState(() => _photoUrl = url);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _addTo(List<String> list, TextEditingController c) {
    final v = c.text.trim();
    if (v.isEmpty) return;
    setState(() {
      if (!list.any((e) => e.toLowerCase() == v.toLowerCase())) list.add(v);
      c.clear();
    });
  }

  Future<void> _pickTime(bool start) async {
    final t = await showTimePicker(context: context, initialTime: start ? _start : _end);
    if (t == null || !mounted) return;
    setState(() => start ? _start = t : _end = t);
  }

  String? _problem() {
    if (_types.isEmpty) return 'Pick at least one trainer category';
    if (_modes.isEmpty) return 'Pick at least one training mode';
    if (_start.hour * 60 + _start.minute >= _end.hour * 60 + _end.minute) return 'Working hours: start must be before end';
    if (_uploading) return 'Wait for the photo to finish uploading';
    return null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) {
      toast(context, 'Check the highlighted fields', error: true);
      return;
    }
    final problem = _problem();
    if (problem != null) {
      toast(context, problem, error: true);
      return;
    }
    _addTo(_certs, _certInput);
    _addTo(_specs, _specInput);

    // Specializations are required by the API; fall back to the chosen category names.
    final labels = {for (final g in widget.groups) for (final t in g.types) t.key: t.label};
    final specs = _specs.isNotEmpty ? _specs : [for (final k in _types) ?labels[k]];

    setState(() => _busy = true);
    try {
      final saved = await context.read<PartnerSession>().api.saveTrainerProfileDetails({
        'name': _name.text.trim(),
        'bio': _bio.text.trim(),
        'photoUrl': ?_photoUrl,
        'certifications': _certs,
        'specializations': specs,
        'trainerTypes': _types.toList(),
        'trainingModes': _modes.toList(),
        'hourlyRatePaise': int.parse(_rate.text.trim()) * 100,
        'bufferMinutes': int.parse(_buffer.text.trim()),
        'workingHours': {'start': _hm(_start), 'end': _hm(_end)},
      });
      if (!mounted) return;
      toast(context, widget.details == null ? 'Trainer profile created' : 'Profile saved');
      widget.onSaved(saved);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              // Photo + identity
              AppCard(
                child: Column(children: [
                  Tap(
                    onTap: _uploading ? null : _pickPhoto,
                    child: Stack(clipBehavior: Clip.none, children: [
                      PersonAvatar(name: _name.text.isEmpty ? 'Trainer' : _name.text, photoUrl: _photoUrl, size: 96),
                      if (_uploading)
                        const Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: Color(0x88000000), shape: BoxShape.circle),
                            child: Center(child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.6, color: Colors.white))),
                          ),
                        ),
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2.5),
                          ),
                          child: const Icon(Icons.photo_camera_rounded, color: Colors.white, size: 16),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  Text(_photoUrl == null ? 'Add a clear, friendly photo' : 'Tap to change photo',
                      style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Name members see', prefixIcon: Icon(Icons.person_outline_rounded)),
                    validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your name' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _bio,
                    maxLines: 5,
                    minLines: 3,
                    maxLength: 600,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'About you',
                      hintText: 'Experience, coaching style, results you help members get…',
                      alignLabelWithHint: true,
                    ),
                    validator: (v) => (v ?? '').trim().length < 10 ? 'Write at least a sentence (10+ characters)' : null,
                  ),
                ]),
              ),

              // BRD §6 trainer categories
              SectionTitle('Trainer categories',
                  subtitle: 'Members find you under these · ${_types.length}/$_maxTypes selected',
                  padding: const EdgeInsets.fromLTRB(0, 24, 0, 12)),
              AppCard(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final g in widget.groups) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 8),
                      child: Row(children: [
                        Expanded(
                          child: Text(g.label.toUpperCase(),
                              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: AppColors.text3, letterSpacing: 0.8)),
                        ),
                        if (g.types.any((t) => _types.contains(t.key)))
                          Tag('${g.types.where((t) => _types.contains(t.key)).length}', color: AppColors.primary, dense: true),
                      ]),
                    ),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final t in g.types) _typeChip(t),
                    ]),
                  ],
                ]),
              ),

              const SectionTitle('Training modes', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
              Row(children: [
                for (final m in _modeInfo.keys) ...[
                  if (m != _modeInfo.keys.first) const SizedBox(width: 10),
                  Expanded(child: _modeTile(m)),
                ],
              ]),

              const SectionTitle('Rate & schedule', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
              AppCard(
                child: Column(children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: TextFormField(
                        controller: _rate,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(labelText: 'Hourly rate', prefixText: '₹ ', suffixText: '/hr'),
                        validator: (v) => (int.tryParse((v ?? '').trim()) ?? 0) < 100 ? 'Minimum ₹100' : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _buffer,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(labelText: 'Travel buffer', suffixText: 'min'),
                        validator: (v) {
                          final n = int.tryParse((v ?? '').trim());
                          return n == null || n > 120 ? '0–120 min' : null;
                        },
                      ),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Buffer is kept free between home visits for travel and prep.',
                        style: TextStyle(color: AppColors.text3, fontSize: 12)),
                  ),
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(child: _timeBox('Day starts', _start, () => _pickTime(true))),
                    const SizedBox(width: 12),
                    Expanded(child: _timeBox('Day ends', _end, () => _pickTime(false))),
                  ]),
                ]),
              ),

              const SectionTitle('Certifications', subtitle: 'Shown on your profile and checked during verification',
                  padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
              AppCard(
                child: _TagInput(
                  values: _certs,
                  controller: _certInput,
                  hint: 'e.g. ACE CPT, Yoga Alliance RYT-200',
                  icon: Icons.workspace_premium_rounded,
                  onAdd: () => _addTo(_certs, _certInput),
                  onRemove: (v) => setState(() => _certs.remove(v)),
                ),
              ),

              const SectionTitle('Specializations', subtitle: 'Optional highlights · we use your categories if empty',
                  padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _TagInput(
                    values: _specs,
                    controller: _specInput,
                    hint: 'Add your own',
                    icon: Icons.star_outline_rounded,
                    onAdd: () => _addTo(_specs, _specInput),
                    onRemove: (v) => setState(() => _specs.remove(v)),
                  ),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final s in _specSuggestions.where((s) => !_specs.contains(s)))
                      ActionChip(
                        avatar: const Icon(Icons.add_rounded, size: 16),
                        label: Text(s),
                        onPressed: () => setState(() => _specs.add(s)),
                      ),
                  ]),
                ]),
              ),
            ],
          ),
        ),
      ),
      BottomActionBar(
        child: AppButton(label: widget.details == null ? 'Create trainer profile' : 'Save profile', onPressed: _save, busy: _busy),
      ),
    ]);
  }

  Widget _typeChip(TrainerTypeOption t) {
    final on = _types.contains(t.key);
    final full = !on && _types.length >= _maxTypes;
    return Tap(
      onTap: () {
        if (full) {
          toast(context, 'You can pick up to $_maxTypes categories', error: true);
          return;
        }
        setState(() => on ? _types.remove(t.key) : _types.add(t.key));
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: on ? AppColors.primarySoft : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? AppColors.primary : AppColors.line, width: on ? 1.4 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (on) ...[const Icon(Icons.check_rounded, size: 16, color: AppColors.primary), const SizedBox(width: 4)],
          Text(t.label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                  color: on ? AppColors.primaryDeep : (full ? AppColors.text3 : AppColors.text))),
        ]),
      ),
    );
  }

  Widget _modeTile(String m) {
    final info = _mode(m);
    final on = _modes.contains(m);
    return Tap(
      onTap: () => setState(() => on ? _modes.remove(m) : _modes.add(m)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: on ? info.$4 : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: on ? info.$3 : AppColors.line, width: on ? 1.5 : 1),
          boxShadow: on ? null : AppShadows.soft,
        ),
        child: Column(children: [
          Icon(info.$2, color: on ? info.$3 : AppColors.text3),
          const SizedBox(height: 6),
          Text(info.$1, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: on ? info.$3 : AppColors.text2)),
        ]),
      ),
    );
  }

  Widget _timeBox(String label, TimeOfDay t, VoidCallback onTap) => Tap(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.schedule_rounded, size: 18, color: AppColors.text2),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontSize: 11, color: AppColors.text3, fontWeight: FontWeight.w700)),
                Text(t.format(context), style: const TextStyle(fontWeight: FontWeight.w800)),
              ]),
            ),
          ]),
        ),
      );
}

/// Text field + removable chips for short lists (certifications, specializations).
class _TagInput extends StatelessWidget {
  const _TagInput({
    required this.values,
    required this.controller,
    required this.hint,
    required this.icon,
    required this.onAdd,
    required this.onRemove,
  });

  final List<String> values;
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: controller,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => onAdd(),
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: Icon(icon),
          suffixIcon: IconButton(tooltip: 'Add', onPressed: onAdd, icon: const Icon(Icons.add_circle_rounded, color: AppColors.primary)),
        ),
      ),
      if (values.isNotEmpty) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final v in values)
            InputChip(
              label: Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
              onDeleted: () => onRemove(v),
              deleteIcon: const Icon(Icons.close_rounded, size: 16),
            ),
        ]),
      ],
    ]);
  }
}
