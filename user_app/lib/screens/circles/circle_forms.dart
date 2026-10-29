import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/circles_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'circles_common.dart';

String _hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
TimeOfDay _parse(String s, TimeOfDay fallback) {
  final parts = s.split(':');
  if (parts.length < 2) return fallback;
  return TimeOfDay(hour: int.tryParse(parts[0]) ?? fallback.hour, minute: int.tryParse(parts[1]) ?? fallback.minute);
}

/// Create a circle (or edit one when [existing] is given). Pops with the circle id.
class CircleFormScreen extends StatefulWidget {
  const CircleFormScreen({super.key, this.existing});
  final CircleSummary? existing;

  @override
  State<CircleFormScreen> createState() => _CircleFormScreenState();
}

class _CircleFormScreenState extends State<CircleFormScreen> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _place = TextEditingController(text: widget.existing?.placeName);
  late final _area = TextEditingController(text: widget.existing?.area);
  late final _city = TextEditingController(text: widget.existing?.city ?? context.read<Session>().user?.city);
  late final _desc = TextEditingController(text: widget.existing?.description);
  late String _activity = widget.existing?.activity ?? 'yoga';
  late Set<int> _days = {...?widget.existing?.days};
  late TimeOfDay _start = _parse(widget.existing?.startTime ?? '06:00', const TimeOfDay(hour: 6, minute: 0));
  late TimeOfDay _end = _parse(widget.existing?.endTime ?? '07:00', const TimeOfDay(hour: 7, minute: 0));
  late double? _lat = widget.existing?.lat;
  late double? _lng = widget.existing?.lng;
  bool _locating = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing == null) _days = {1, 2, 3, 4, 5, 6, 7};
  }

  @override
  void dispose() {
    for (final c in [_name, _place, _area, _city, _desc]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pin() async {
    setState(() => _locating = true);
    final pos = await currentPosition();
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (pos != null) {
        _lat = pos.latitude;
        _lng = pos.longitude;
      }
    });
    if (pos == null) toast(context, CirclesPrefs.instance.t('noLocation'), error: true);
  }

  Future<void> _pickTime(bool start) async {
    final t = await showTimePicker(context: context, initialTime: start ? _start : _end);
    if (t == null || !mounted) return;
    setState(() => start ? _start = t : _end = t);
  }

  Future<void> _save() async {
    final p = CirclesPrefs.instance;
    if (_name.text.trim().length < 3 || _place.text.trim().length < 2 || _city.text.trim().length < 2) {
      toast(context, p.t('needFields'), error: true);
      return;
    }
    if (_days.isEmpty) {
      toast(context, p.t('needDay'), error: true);
      return;
    }
    setState(() => _busy = true);
    final fields = {
      'name': _name.text.trim(),
      'activity': _activity,
      'placeName': _place.text.trim(),
      'area': _area.text.trim(),
      'city': _city.text.trim(),
      'description': _desc.text.trim(),
      'lat': _lat,
      'lng': _lng,
      'days': (_days.toList()..sort()),
      'startTime': _hm(_start),
      'endTime': _hm(_end),
    };
    try {
      final api = context.read<Session>().api;
      final c = widget.existing == null ? await api.createCircle(fields) : await api.updateCircle(widget.existing!.id, fields);
      if (!mounted) return;
      if (widget.existing == null) toast(context, p.t('created'), icon: Icons.celebration_rounded);
      Navigator.pop(context, c.id);
    } catch (e) {
      if (!mounted) return;
      toast(context, friendlyError(e), error: true);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CirclesShell(child: Builder(builder: (context) {
      final p = circlesOf(context);
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text(widget.existing == null ? p.t('create') : p.t('edit')),
          actions: const [CirclesA11yToggles(), SizedBox(width: 12)],
        ),
        bottomNavigationBar: BottomActionBar(
          child: AppButton(
            label: widget.existing == null ? p.t('createBtn') : p.t('save'),
            icon: Icons.check_rounded,
            busy: _busy,
            onPressed: _save,
          ),
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _field(_name, p.t('nameLabel'), hint: p.t('nameHint'), cap: TextCapitalization.words),
              const SizedBox(height: 16),
              Text(p.t('activity'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final a in circleActivities)
                  ChoiceChip(
                    avatar: Icon(circleVisual(a).icon, size: 18, color: circleVisual(a).color),
                    label: Text(activityLabel(p, a)),
                    selected: _activity == a,
                    onSelected: (_) => setState(() => _activity = a),
                  ),
              ]),
              const SizedBox(height: 16),
              _field(_desc, p.t('descLabel'), hint: p.t('descHint'), lines: 2),
            ]),
          ),
          SectionTitle(p.t('placeLabel'), padding: const EdgeInsets.fromLTRB(0, 22, 0, 10)),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _field(_place, p.t('placeLabel'), hint: p.t('placeHint'), cap: TextCapitalization.words),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _field(_area, p.t('areaLabel'), cap: TextCapitalization.words)),
                const SizedBox(width: 12),
                Expanded(child: _field(_city, p.t('cityLabel'), cap: TextCapitalization.words)),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                IconBubble(Icons.location_on_rounded, color: _lat != null ? AppColors.green : AppColors.text3),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.t('pinLabel'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      kIsWeb && _lat == null ? p.t('pinWeb') : (_lat != null ? p.t('pinSet') : p.t('pinNone')),
                      style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35),
                    ),
                  ]),
                ),
              ]),
              if (!kIsWeb) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _locating ? null : _pin,
                      icon: _locating
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.my_location_rounded),
                      label: Text(p.t('pinUse')),
                    ),
                  ),
                  if (_lat != null) ...[
                    const SizedBox(width: 8),
                    TextButton(onPressed: () => setState(() => _lat = _lng = null), child: Text(p.t('pinClear'))),
                  ],
                ]),
              ],
            ]),
          ),
          SectionTitle(p.t('days'), padding: const EdgeInsets.fromLTRB(0, 22, 0, 10)),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilterChip(
                  label: Text(p.t('everyday')),
                  selected: _days.length == 7,
                  onSelected: (v) => setState(() => _days = v ? {1, 2, 3, 4, 5, 6, 7} : {}),
                ),
                for (var d = 1; d <= 7; d++)
                  FilterChip(
                    label: Text(dayShort(p, d)),
                    selected: _days.contains(d),
                    onSelected: (v) => setState(() => v ? _days.add(d) : _days.remove(d)),
                  ),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: _timeTile(p.t('startTime'), _start, () => _pickTime(true))),
                const SizedBox(width: 12),
                Expanded(child: _timeTile(p.t('endTime'), _end, () => _pickTime(false))),
              ]),
            ]),
          ),
        ]),
      );
    }));
  }

  Widget _timeTile(String label, TimeOfDay t, VoidCallback onTap) => Tap(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Icon(Icons.schedule_rounded, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(color: AppColors.text2, fontSize: 12)),
                Text(clock12(_hm(t)), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ]),
            ),
          ]),
        ),
      );

  Widget _field(TextEditingController c, String label,
          {String? hint, int lines = 1, TextCapitalization cap = TextCapitalization.sentences}) =>
      TextField(
        controller: c,
        maxLines: lines,
        textCapitalization: cap,
        decoration: InputDecoration(labelText: label, hintText: hint),
      );
}

/// Join with the leader's invite code. Returns the circle id.
Future<String?> showJoinByCodeSheet(BuildContext context) => showAppSheet<String>(
      context,
      builder: (_) => const CirclesShell(child: _CodeSheet(family: false)),
    );

/// Follow a parent with their family code. Returns 'ok' on success.
Future<String?> showFamilyCodeSheet(BuildContext context) => showAppSheet<String>(
      context,
      builder: (_) => const CirclesShell(child: _CodeSheet(family: true)),
    );

class _CodeSheet extends StatefulWidget {
  const _CodeSheet({required this.family});
  final bool family;

  @override
  State<_CodeSheet> createState() => _CodeSheetState();
}

class _CodeSheetState extends State<_CodeSheet> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim().toUpperCase();
    if (code.length < 4) return;
    setState(() => _busy = true);
    final api = context.read<Session>().api;
    try {
      if (widget.family) {
        await api.linkFamily(code);
        if (!mounted) return;
        Navigator.pop(context, 'ok');
      } else {
        final id = await api.joinCircleByCode(code);
        if (!mounted) return;
        Navigator.pop(context, id);
      }
    } catch (e) {
      if (!mounted) return;
      toast(context, friendlyError(e), error: true);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = circlesOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.family ? p.t('followParent') : p.t('enterCode'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(widget.family ? p.t('followParentSub') : p.t('inviteCode'), style: const TextStyle(color: AppColors.text2)),
        const SizedBox(height: 16),
        TextField(
          controller: _code,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')), LengthLimitingTextInputFormatter(12)],
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 4),
          decoration: InputDecoration(hintText: p.t('codeHint')),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        AppButton(
          label: widget.family ? p.t('follow') : p.t('joinBtn'),
          icon: widget.family ? Icons.family_restroom_rounded : Icons.group_add_rounded,
          busy: _busy,
          onPressed: _submit,
        ),
      ]),
    );
  }
}

/// Leader adds a special session. Returns true when created.
Future<bool?> showAddSpecialSheet(BuildContext context, CircleSummary circle) => showAppSheet<bool>(
      context,
      builder: (_) => CirclesShell(child: _SpecialSheet(circle: circle)),
    );

class _SpecialSheet extends StatefulWidget {
  const _SpecialSheet({required this.circle});
  final CircleSummary circle;

  @override
  State<_SpecialSheet> createState() => _SpecialSheetState();
}

class _SpecialSheetState extends State<_SpecialSheet> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  String _kind = 'special';
  DateTime? _date;
  TimeOfDay? _start;
  TimeOfDay? _end;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
      initialDate: _date ?? now,
    );
    if (d != null && mounted) setState(() => _date = d);
  }

  Future<void> _pickTime(bool start) async {
    final init = start
        ? _start ?? _parse(widget.circle.startTime, const TimeOfDay(hour: 6, minute: 0))
        : _end ?? _parse(widget.circle.endTime, const TimeOfDay(hour: 7, minute: 0));
    final t = await showTimePicker(context: context, initialTime: init);
    if (t != null && mounted) setState(() => start ? _start = t : _end = t);
  }

  Future<void> _save() async {
    final p = CirclesPrefs.instance;
    if (_title.text.trim().length < 3 || _date == null) {
      toast(context, _date == null ? p.t('pickDate') : p.t('specialTitle'), error: true);
      return;
    }
    setState(() => _busy = true);
    final d = _date!;
    try {
      await context.read<Session>().api.createCircleSpecial(widget.circle.id, {
        'title': _title.text.trim(),
        'kind': _kind,
        'date': '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
        'startTime': _start == null ? null : _hm(_start!),
        'endTime': _end == null ? null : _hm(_end!),
        'note': _note.text.trim(),
      });
      if (!mounted) return;
      toast(context, p.t('specialCreated'), icon: Icons.celebration_rounded);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      toast(context, friendlyError(e), error: true);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = circlesOf(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(p.t('addSpecial'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 16),
        TextField(
          controller: _title,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: p.t('specialTitle'), hintText: p.t('specialTitleHint')),
        ),
        const SizedBox(height: 14),
        Text(p.t('specialType'), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final k in ['special', 'festival', 'yoga_day', 'health_camp'])
            ChoiceChip(label: Text(p.t('kind_$k')), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
        ]),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: _pickDate,
          icon: const Icon(Icons.event_rounded),
          label: Text(_date == null
              ? p.t('pickDate')
              : friendlyDate(p, '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}')),
        ),
        const SizedBox(height: 10),
        Text(p.t('specialTime'), style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => _pickTime(true),
              child: Text(_start == null ? clock12(widget.circle.startTime) : clock12(_hm(_start!))),
            ),
          ),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('–')),
          Expanded(
            child: OutlinedButton(
              onPressed: () => _pickTime(false),
              child: Text(_end == null ? clock12(widget.circle.endTime) : clock12(_hm(_end!))),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        TextField(controller: _note, maxLines: 2, decoration: InputDecoration(labelText: p.t('specialNote'))),
        const SizedBox(height: 18),
        AppButton(label: p.t('save'), icon: Icons.check_rounded, busy: _busy, onPressed: _save),
      ]),
    );
  }
}
