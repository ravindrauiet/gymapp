// Small form building blocks shared by the trainer / clinic / chemist / store listing wizard.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';

const weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const weekdayLabels = {
  'mon': 'Mon',
  'tue': 'Tue',
  'wed': 'Wed',
  'thu': 'Thu',
  'fri': 'Fri',
  'sat': 'Sat',
  'sun': 'Sun',
};

List<String> strList(Object? v) => v is List ? [for (final e in v) '$e'] : <String>[];
int intOf(Object? v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
double? doubleOf(Object? v) => v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));

/// Rupees text ↔ paise.
String rupeesText(Object? paise) {
  final p = intOf(paise);
  return p == 0 ? '' : (p % 100 == 0 ? '${p ~/ 100}' : (p / 100).toStringAsFixed(2));
}

int paiseOf(String rupees) => ((double.tryParse(rupees.trim()) ?? 0) * 100).round();

String rupees(int paise) {
  final r = paise / 100;
  return '₹${r == r.roundToDouble() ? r.toInt() : r.toStringAsFixed(2)}';
}

TimeOfDay parseHm(String? s, {TimeOfDay fallback = const TimeOfDay(hour: 9, minute: 0)}) {
  if (s == null || !s.contains(':')) return fallback;
  final p = s.split(':');
  return TimeOfDay(hour: int.tryParse(p[0]) ?? fallback.hour, minute: int.tryParse(p[1]) ?? fallback.minute);
}

String hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String hmLabel(String s) {
  final t = parseHm(s);
  final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
  return '$h${t.minute == 0 ? '' : ':${t.minute.toString().padLeft(2, '0')}'} ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
}

/// One availability window: a weekday + start/end (HH:MM).
class TimeWindow {
  TimeWindow(this.weekday, this.start, this.end);
  String weekday;
  String start;
  String end;

  /// Reads `{weekday, start, end}` or `{weekday, opensAt, closesAt}`.
  static TimeWindow fromJson(Json j) =>
      TimeWindow('${j['weekday'] ?? 'mon'}', '${j['start'] ?? j['opensAt'] ?? '09:00'}', '${j['end'] ?? j['closesAt'] ?? '18:00'}');

  Json toJson({bool opensCloses = false}) => opensCloses
      ? {'weekday': weekday, 'opensAt': start, 'closesAt': end}
      : {'weekday': weekday, 'start': start, 'end': end};

  bool get valid => parseHm(end).hour * 60 + parseHm(end).minute > parseHm(start).hour * 60 + parseHm(start).minute;
}

/// Titled card holding a group of fields.
class FieldSection extends StatelessWidget {
  const FieldSection({super.key, required this.title, this.subtitle, required this.child, this.icon});
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, size: 18, color: AppColors.primary), const SizedBox(width: 8)],
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
            ]),
            if (subtitle != null) ...[
              const SizedBox(height: 3),
              Text(subtitle!, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
            ],
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

/// Callout box (info / warning).
class InfoNote extends StatelessWidget {
  const InfoNote(this.text, {super.key, this.icon = Icons.info_rounded, this.color = AppColors.blue, this.bg});
  final String text;
  final IconData icon;
  final Color color;
  final Color? bg;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: bg ?? color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w600)),
          ),
        ]),
      );
}

/// Multi-select chips.
class MultiSelectChips extends StatelessWidget {
  const MultiSelectChips({super.key, required this.options, required this.selected, required this.onChanged});
  final Map<String, String> options;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final e in options.entries)
          FilterChip(
            label: Text(e.value),
            selected: selected.contains(e.key),
            showCheckmark: true,
            onSelected: (on) => onChanged(on ? ({...selected, e.key}) : ({...selected}..remove(e.key))),
          ),
      ]);
}

/// Free-text tags with optional suggestions ("Achievements", "Languages").
class TagInput extends StatefulWidget {
  const TagInput({super.key, required this.values, required this.onChanged, required this.hint, this.suggestions = const []});
  final List<String> values;
  final ValueChanged<List<String>> onChanged;
  final String hint;
  final List<String> suggestions;

  @override
  State<TagInput> createState() => _TagInputState();
}

class _TagInputState extends State<TagInput> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _add(String v) {
    final s = v.trim();
    if (s.isEmpty) return;
    if (!widget.values.any((e) => e.toLowerCase() == s.toLowerCase())) widget.onChanged([...widget.values, s]);
    _c.clear();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.suggestions.where((s) => !widget.values.any((v) => v.toLowerCase() == s.toLowerCase())).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.values.isNotEmpty) ...[
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final v in widget.values)
            InputChip(
              label: Text(v),
              onDeleted: () => widget.onChanged([...widget.values]..remove(v)),
            ),
        ]),
        const SizedBox(height: 10),
      ],
      TextField(
        controller: _c,
        textInputAction: TextInputAction.done,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: _add,
        decoration: InputDecoration(
          hintText: widget.hint,
          suffixIcon: IconButton(icon: const Icon(Icons.add_circle_rounded), onPressed: () => _add(_c.text)),
        ),
      ),
      if (left.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in left)
            ActionChip(
              avatar: const Icon(Icons.add_rounded, size: 16),
              label: Text(s, style: const TextStyle(fontSize: 12.5)),
              onPressed: () => _add(s),
            ),
        ]),
      ],
    ]);
  }
}

/// Weekly time windows: several per day allowed (split shifts / multiple OPD sessions).
class TimeWindowsEditor extends StatelessWidget {
  const TimeWindowsEditor({super.key, required this.windows, required this.onChanged, this.addLabel = 'Add time window'});
  final List<TimeWindow> windows;
  final ValueChanged<List<TimeWindow>> onChanged;
  final String addLabel;

  Future<void> _edit(BuildContext context, TimeWindow? w) async {
    final r = await showAppSheet<List<TimeWindow>>(context, builder: (_) => _WindowSheet(initial: w));
    if (r == null) return;
    final list = [...windows];
    if (w != null) list.remove(w);
    list.addAll(r);
    list.sort((a, b) {
      final d = weekdays.indexOf(a.weekday).compareTo(weekdays.indexOf(b.weekday));
      return d != 0 ? d : a.start.compareTo(b.start);
    });
    onChanged(list);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (windows.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('No timings yet.', style: TextStyle(color: AppColors.text3)),
        ),
      for (final d in weekdays)
        if (windows.any((w) => w.weekday == d))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 44,
                child: Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Text(weekdayLabels[d]!, style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
              Expanded(
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final w in windows.where((w) => w.weekday == d))
                    InputChip(
                      label: Text('${hmLabel(w.start)} – ${hmLabel(w.end)}'),
                      onPressed: () => _edit(context, w),
                      onDeleted: () => onChanged([...windows]..remove(w)),
                    ),
                ]),
              ),
            ]),
          ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => _edit(context, null),
          icon: const Icon(Icons.add_rounded),
          label: Text(addLabel),
        ),
      ),
    ]);
  }
}

class _WindowSheet extends StatefulWidget {
  const _WindowSheet({this.initial});
  final TimeWindow? initial;

  @override
  State<_WindowSheet> createState() => _WindowSheetState();
}

class _WindowSheetState extends State<_WindowSheet> {
  late final Set<String> _days = {widget.initial?.weekday ?? 'mon', if (widget.initial == null) ...['tue', 'wed', 'thu', 'fri']};
  late TimeOfDay _start = parseHm(widget.initial?.start, fallback: const TimeOfDay(hour: 9, minute: 0));
  late TimeOfDay _end = parseHm(widget.initial?.end, fallback: const TimeOfDay(hour: 13, minute: 0));
  String? _error;

  Future<void> _pick(bool start) async {
    final t = await showTimePicker(context: context, initialTime: start ? _start : _end);
    if (t != null) setState(() => start ? _start = t : _end = t);
  }

  void _done() {
    if (_days.isEmpty) return setState(() => _error = 'Pick at least one day');
    if (_end.hour * 60 + _end.minute <= _start.hour * 60 + _start.minute) {
      return setState(() => _error = 'End time must be after the start time');
    }
    Navigator.pop(context, [
      for (final d in weekdays)
        if (_days.contains(d)) TimeWindow(d, hm(_start), hm(_end)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    Widget timeBox(String label, TimeOfDay t, bool start) => Expanded(
          child: AppCard(
            onTap: () => _pick(start),
            shadow: false,
            border: true,
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(hmLabel(hm(t)), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ]),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.initial == null ? 'Add timings' : 'Edit timing',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final d in weekdays)
            FilterChip(
              label: Text(weekdayLabels[d]!),
              selected: _days.contains(d),
              showCheckmark: false,
              onSelected: widget.initial != null
                  ? (_) => setState(() => _days
                    ..clear()
                    ..add(d))
                  : (on) => setState(() => on ? _days.add(d) : _days.remove(d)),
            ),
        ]),
        const SizedBox(height: 14),
        Row(children: [timeBox('From', _start, true), const SizedBox(width: 10), timeBox('To', _end, false)]),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_error!, style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 18),
        AppButton(label: 'Done', icon: Icons.check_rounded, onPressed: _done),
      ]),
    );
  }
}

Future<String?> _pickAndUpload(BuildContext context) async {
  final XFile? f;
  try {
    f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 82);
  } catch (_) {
    if (context.mounted) toast(context, 'Could not open your photos', error: true);
    return null;
  }
  if (f == null || !context.mounted) return null;
  try {
    return await context.read<PartnerSession>().api.upload(f);
  } catch (e) {
    if (context.mounted) toast(context, friendlyError(e), error: true);
    return null;
  }
}

/// A single round/square photo (trainer photo, store logo).
class SinglePhotoField extends StatefulWidget {
  const SinglePhotoField({super.key, required this.url, required this.onChanged, required this.label, this.round = true});
  final String? url;
  final ValueChanged<String?> onChanged;
  final String label;
  final bool round;

  @override
  State<SinglePhotoField> createState() => _SinglePhotoFieldState();
}

class _SinglePhotoFieldState extends State<SinglePhotoField> {
  bool _busy = false;

  Future<void> _pick() async {
    setState(() => _busy = true);
    final url = await _pickAndUpload(context);
    if (!mounted) return;
    setState(() => _busy = false);
    if (url != null) widget.onChanged(url);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.round ? 44.0 : 18.0;
    return Row(children: [
      Tap(
        onTap: _busy ? null : _pick,
        child: Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(r),
            border: Border.all(color: AppColors.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: _busy
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.4))
              : widget.url == null
                  ? const Icon(Icons.add_a_photo_rounded, color: AppColors.text3, size: 30)
                  : NetImage(widget.url, fallback: AppImages.gym, width: 88, height: 88),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.label, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          const Text('Clear, well-lit, no text overlays.', style: TextStyle(color: AppColors.text3, fontSize: 12.5)),
          TextButton(
            onPressed: _busy ? null : _pick,
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            child: Text(widget.url == null ? 'Upload' : 'Change'),
          ),
        ]),
      ),
    ]);
  }
}

/// Grid of photos with add / remove (max [max]).
class PhotoGridField extends StatefulWidget {
  const PhotoGridField({super.key, required this.urls, required this.onChanged, this.max = 10});
  final List<String> urls;
  final ValueChanged<List<String>> onChanged;
  final int max;

  @override
  State<PhotoGridField> createState() => _PhotoGridFieldState();
}

class _PhotoGridFieldState extends State<PhotoGridField> {
  bool _busy = false;

  Future<void> _add() async {
    setState(() => _busy = true);
    final url = await _pickAndUpload(context);
    if (!mounted) return;
    setState(() => _busy = false);
    if (url != null) widget.onChanged([...widget.urls, url]);
  }

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        for (final (i, u) in widget.urls.indexed)
          Stack(fit: StackFit.expand, children: [
            NetImage(u, fallback: AppImages.gym, radius: 14),
            if (i == 0)
              const Positioned(left: 6, bottom: 6, child: Tag('COVER', solid: true, dense: true, color: AppColors.ink)),
            Positioned(
              right: 4,
              top: 4,
              child: Tap(
                onTap: () => widget.onChanged([...widget.urls]..removeAt(i)),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded, size: 14, color: Colors.white),
                ),
              ),
            ),
          ]),
        if (widget.urls.length < widget.max)
          Tap(
            onTap: _busy ? null : _add,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.line),
              ),
              child: _busy
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2.4))
                  : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.add_photo_alternate_rounded, color: AppColors.text3),
                      SizedBox(height: 4),
                      Text('Add photo', style: TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w700)),
                    ]),
            ),
          ),
      ],
    );
  }
}

/// Numeric text field helper.
InputDecoration moneyDecoration(String label, {String? helper}) => InputDecoration(
      labelText: label,
      prefixText: '₹ ',
      helperText: helper,
      prefixIcon: const Icon(Icons.currency_rupee_rounded),
    );

List<TextInputFormatter> get digitsOnly => [FilteringTextInputFormatter.digitsOnly];
List<TextInputFormatter> get decimalOnly => [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))];
