part of '../venue_editor_screen.dart';

// ---------------------------------------------------------------------------
// Step 4 — timings (split shifts, per-day hours, ladies-only, holidays) & FitKey pass access (BRD §4)
// ---------------------------------------------------------------------------
class _TimingsStep extends StatefulWidget {
  const _TimingsStep({required this.venue, required this.schedule, required this.onChanged});

  final PartnerVenue venue;
  final WeekSchedule schedule;
  final VoidCallback onChanged;

  @override
  State<_TimingsStep> createState() => _TimingsStepState();
}

class _TimingsStepState extends State<_TimingsStep> {
  WeekSchedule get _s => widget.schedule;
  PartnerVenue get _v => widget.venue;
  late bool _perDay = !_s.sameEveryDay;
  late List<Shift> _template = _s.template;
  late bool _ladies = _s.ladies.isNotEmpty;

  void _changed() {
    // Keep the venue's hours in sync whenever the schedule is valid (saved with the draft).
    if (validateSchedule(_s) == null) _s.writeTo(_v);
    setState(() {});
    widget.onChanged();
  }

  // ---- open days ------------------------------------------------------------------------------------------------

  void _setDays(Iterable<String> days) {
    final set = days.toSet();
    for (final d in weekdays) {
      if (!set.contains(d)) {
        _s.open[d] = [];
      } else if (_s.open[d]!.isEmpty) {
        _s.open[d] = _template.map((x) => x.copy()).toList();
      }
    }
    if (!_perDay) _s.applyToDays(set, _template);
    _changed();
  }

  void _toggleDay(String d) {
    final days = _s.openDays.toSet();
    days.contains(d) ? days.remove(d) : days.add(d);
    _setDays(days);
  }

  // ---- shifts ---------------------------------------------------------------------------------------------------

  Future<void> _editShift(List<Shift> shifts, int i, bool start) async {
    final t = await _pickTime(context, start ? shifts[i].start : shifts[i].end, help: start ? 'OPENS AT' : 'CLOSES AT');
    if (t == null) return;
    start ? shifts[i].start = t : shifts[i].end = t;
    shifts.sort((a, b) => a.startMin.compareTo(b.startMin));
    _afterShiftEdit(shifts);
  }

  void _afterShiftEdit(List<Shift> shifts) {
    if (!_perDay && identical(shifts, _template)) _s.applyToDays(_s.openDays, _template);
    _changed();
  }

  void _addShift(List<Shift> shifts) {
    final lastEnd = shifts.isEmpty ? 6 * 60 : shifts.last.endMin;
    final start = (lastEnd + 60).clamp(0, 23 * 60);
    final end = (start + 4 * 60).clamp(start + 30, 24 * 60 - 1);
    shifts.add(Shift(fromMinutes(start), fromMinutes(end)));
    _afterShiftEdit(shifts);
  }

  void _removeShift(List<Shift> shifts, int i) {
    shifts.removeAt(i);
    _afterShiftEdit(shifts);
  }

  void _setPerDay(bool on) {
    setState(() => _perDay = on);
    if (!on) {
      _template = _s.template;
      _s.applyToDays(_s.openDays, _template);
    }
    _changed();
  }

  void _copyToAll(String day) {
    _template = _s.open[day]!.map((x) => x.copy()).toList();
    _s.applyToDays(_s.openDays, _template);
    toast(context, '${weekdayLong[day]} hours copied to all open days');
    _changed();
  }

  // ---- closures -------------------------------------------------------------------------------------------------

  Future<void> _addClosure() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'CLOSED ON',
    );
    if (date == null || !mounted) return;
    final iso = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    if (_v.closures.any((c) => c.closedOn == iso && c.wholeDay)) {
      toast(context, 'That date is already marked closed');
      return;
    }
    final closure = await showAppSheet<VenueClosure>(context, builder: (_) => _ClosureSheet(closedOn: iso, date: date));
    if (closure == null) return;
    _v.closures
      ..add(closure)
      ..sort((a, b) => a.closedOn.compareTo(b.closedOn));
    _changed();
  }

  // ---- build ----------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final error = validateSchedule(_s);
    final passError = validatePassBlocks(_v.fitkeyPassMode, _v.passBlocks);
    final openDays = _s.openDays;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _StepIntro('When are you open?', 'Members can only book and check in during these hours.'),
        const Text('OPEN ON', style: _caps),
        const SizedBox(height: 10),
        _DayToggles(selected: openDays, onToggle: _toggleDay),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _shortcut('All 7 days', weekdays),
          _shortcut('Mon – Sat', weekdays.take(6)),
          _shortcut('Weekdays', weekdays.take(5)),
        ]),
        const SizedBox(height: 18),
        _SwitchCard(
          icon: Icons.calendar_view_week_rounded,
          color: AppColors.blue,
          title: 'Different hours on different days',
          subtitle: _perDay ? 'Set hours for each day below' : 'Same hours every open day',
          value: _perDay,
          onChanged: _setPerDay,
        ),
        const SizedBox(height: 12),
        if (!_perDay)
          AppCard(child: _shiftEditor(_template, title: openDays.isEmpty ? 'Hours' : 'Hours · ${prettyDays(openDays)}'))
        else
          for (final d in openDays)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AppCard(child: _shiftEditor(_s.open[d]!, title: weekdayLong[d]!, day: d)),
            ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: _ErrorLine(error),
          ),
        // ---- ladies-only ----
        const SizedBox(height: 18),
        _SwitchCard(
          icon: Icons.woman_rounded,
          color: AppColors.pink,
          title: 'Ladies-only hours',
          subtitle: 'Times reserved for women members',
          value: _ladies,
          onChanged: (on) {
            setState(() => _ladies = on);
            if (on && _s.ladies.isEmpty) _s.ladies.add(DayWindow(days: List.of(openDays.isEmpty ? weekdays : openDays), start: _defaultLadiesStart()));
            if (!on) _s.ladies.clear();
            _changed();
          },
        ),
        if (_ladies) ...[
          const SizedBox(height: 10),
          for (var i = 0; i < _s.ladies.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _windowCard(
                days: _s.ladies[i].days,
                start: _s.ladies[i].start,
                end: _s.ladies[i].end,
                onStart: (t) => _s.ladies[i].start = t,
                onEnd: (t) => _s.ladies[i].end = t,
                onRemove: () {
                  _s.ladies.removeAt(i);
                  if (_s.ladies.isEmpty) _ladies = false;
                  _changed();
                },
              ),
            ),
          TextButton.icon(
            onPressed: () {
              _s.ladies.add(DayWindow(days: List.of(openDays), start: _defaultLadiesStart()));
              _changed();
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add another ladies-only time'),
          ),
        ],
        // ---- holidays ----
        const SectionTitle('Holidays & closed dates', subtitle: 'Members can\'t book on these dates'),
        if (_v.closures.isEmpty)
          const Text('No closed dates coming up.', style: TextStyle(color: AppColors.text3))
        else
          AppCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              for (final c in List.of(_v.closures))
                ListTile(
                  leading: const IconBubble(Icons.event_busy_rounded, color: AppColors.red, size: 36),
                  title: Text(_prettyDate(c.closedOn), style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text([
                    c.wholeDay ? 'Closed all day' : 'Closed ${prettyRange(c.slotStart!, c.slotEnd!)}',
                    if ((c.note ?? '').trim().isNotEmpty) c.note!.trim(),
                  ].join(' · ')),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red),
                    onPressed: () {
                      _v.closures.remove(c);
                      _changed();
                    },
                  ),
                ),
            ]),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _addClosure,
            icon: const Icon(Icons.event_busy_rounded),
            label: const Text('Add closed date'),
          ),
        ),
        // ---- FitKey pass access ----
        const SectionTitle('FitKey pass access', subtitle: 'Your own members can always come at any open hour'),
        _accessOption(
          'all',
          Icons.all_inclusive_rounded,
          'Allow FitKey pass users at all open hours',
          'Most bookings — recommended',
        ),
        const SizedBox(height: 10),
        _accessOption(
          'blocked',
          Icons.block_rounded,
          'Block FitKey pass users at specific times',
          'E.g. your peak evening hours',
        ),
        if (_v.fitkeyPassMode == 'blocked') ...[
          const SizedBox(height: 12),
          for (var i = 0; i < _v.passBlocks.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _windowCard(
                days: _v.passBlocks[i].days,
                start: _v.passBlocks[i].startsAt,
                end: _v.passBlocks[i].endsAt,
                onStart: (t) => _v.passBlocks[i].startsAt = t,
                onEnd: (t) => _v.passBlocks[i].endsAt = t,
                onRemove: () {
                  _v.passBlocks.removeAt(i);
                  _changed();
                },
                footer: passBlockLabel(_v.passBlocks[i]),
              ),
            ),
          TextButton.icon(
            onPressed: () {
              _v.passBlocks.add(PassBlock());
              _changed();
            },
            icon: const Icon(Icons.add_rounded),
            label: Text(_v.passBlocks.isEmpty ? 'Add a blocked time' : 'Add another blocked time'),
          ),
          if (passError != null) _ErrorLine(passError),
        ],
      ],
    );
  }

  String _defaultLadiesStart() {
    final e = _s.envelope;
    return toMinutes(e.opensAt) <= 10 * 60 && toMinutes(e.closesAt) >= 12 * 60 ? '10:00' : e.opensAt;
  }

  static String _prettyDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${weekdayShort[weekdays[d.weekday - 1]]}, ${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Widget _shortcut(String label, Iterable<String> days) {
    final on = _s.openDays.length == days.length && days.every(_s.openDays.contains);
    return ChoiceChip(
      label: Text(label),
      selected: on,
      showCheckmark: false,
      selectedColor: AppColors.ink,
      labelStyle: TextStyle(fontWeight: FontWeight.w700, color: on ? Colors.white : AppColors.text),
      onSelected: (_) => _setDays(days),
    );
  }

  Widget _shiftEditor(List<Shift> shifts, {required String title, String? day}) {
    final err = validateShifts(shifts);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
        if (shifts.length > 1) const Tag('SPLIT SHIFT', color: AppColors.purple, dense: true),
        if (day != null && _s.openDays.length > 1)
          TextButton(onPressed: () => _copyToAll(day), child: const Text('Copy to all')),
      ]),
      const SizedBox(height: 10),
      for (var i = 0; i < shifts.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _RangeTile(
            start: shifts[i].start,
            end: shifts[i].end,
            error: err != null,
            onStart: () => _editShift(shifts, i, true),
            onEnd: () => _editShift(shifts, i, false),
            onRemove: shifts.length > 1 ? () => _removeShift(shifts, i) : null,
          ),
        ),
      if (shifts.length < 3)
        TextButton.icon(
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
          onPressed: () => _addShift(shifts),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(shifts.length == 1 ? 'Add a break / second shift' : 'Add another shift'),
        ),
    ]);
  }

  Widget _windowCard({
    required List<String> days,
    required String start,
    required String end,
    required ValueChanged<String> onStart,
    required ValueChanged<String> onEnd,
    required VoidCallback onRemove,
    String? footer,
  }) {
    final bad = toMinutes(end) <= toMinutes(start);
    return AppCard(
      border: true,
      shadow: false,
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _DayToggles(
          dense: true,
          selected: days,
          onToggle: (d) {
            days.contains(d) ? days.remove(d) : days.add(d);
            _changed();
          },
        ),
        const SizedBox(height: 10),
        _RangeTile(
          start: start,
          end: end,
          error: bad,
          onStart: () async {
            final t = await _pickTime(context, start, help: 'FROM');
            if (t != null) {
              onStart(t);
              _changed();
            }
          },
          onEnd: () async {
            final t = await _pickTime(context, end, help: 'TO');
            if (t != null) {
              onEnd(t);
              _changed();
            }
          },
          onRemove: onRemove,
        ),
        if (footer != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.visibility_outlined, size: 14, color: AppColors.text3),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Members see: "$footer"',
                  style: const TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w600)),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _accessOption(String mode, IconData icon, String title, String subtitle) {
    final on = _v.fitkeyPassMode == mode;
    return Tap(
      onTap: () {
        _v.fitkeyPassMode = mode;
        if (mode == 'blocked' && _v.passBlocks.isEmpty) _v.passBlocks.add(PassBlock());
        _changed();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: on ? AppColors.primarySoft : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: on ? AppColors.primary : AppColors.line, width: on ? 1.6 : 1),
        ),
        child: Row(children: [
          Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              color: on ? AppColors.primary : AppColors.text3),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(subtitle, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
            ]),
          ),
          Icon(icon, color: on ? AppColors.primary : AppColors.text3),
        ]),
      ),
    );
  }
}

const _caps = TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1);

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.error_outline_rounded, color: AppColors.red, size: 18),
      const SizedBox(width: 6),
      Expanded(
        child: Text(message, style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w700, fontSize: 12.5)),
      ),
    ]);
  }
}

/// Add a holiday: whole day, or only some hours, with an optional note.
class _ClosureSheet extends StatefulWidget {
  const _ClosureSheet({required this.closedOn, required this.date});
  final String closedOn;
  final DateTime date;

  @override
  State<_ClosureSheet> createState() => _ClosureSheetState();
}

class _ClosureSheetState extends State<_ClosureSheet> {
  bool _wholeDay = true;
  String _start = '12:00';
  String _end = '16:00';
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bad = !_wholeDay && toMinutes(_end) <= toMinutes(_start);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Closed on ${_TimingsStepState._prettyDate(widget.closedOn)}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Whole day'), icon: Icon(Icons.event_busy_rounded)),
              ButtonSegment(value: false, label: Text('Some hours'), icon: Icon(Icons.timelapse_rounded)),
            ],
            selected: {_wholeDay},
            onSelectionChanged: (s) => setState(() => _wholeDay = s.first),
          ),
          if (!_wholeDay) ...[
            const SizedBox(height: 12),
            _RangeTile(
              start: _start,
              end: _end,
              error: bad,
              onStart: () async {
                final t = await _pickTime(context, _start, help: 'CLOSED FROM');
                if (t != null) setState(() => _start = t);
              },
              onEnd: () async {
                final t = await _pickTime(context, _end, help: 'CLOSED UNTIL');
                if (t != null) setState(() => _end = t);
              },
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            maxLength: 160,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'e.g. Diwali, maintenance'),
          ),
          const SizedBox(height: 8),
          AppButton(
            label: 'Add closed date',
            onPressed: bad
                ? null
                : () => Navigator.pop(
                      context,
                      VenueClosure(
                        closedOn: widget.closedOn,
                        slotStart: _wholeDay ? null : _start,
                        slotEnd: _wholeDay ? null : _end,
                        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                      ),
                    ),
          ),
        ]),
      ),
    );
  }
}
