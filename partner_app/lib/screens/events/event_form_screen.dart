import 'package:fitkey_core/fitkey_core.dart' show apiDate, formatDayDate, formatShortDate;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/insights_api.dart';
import '../../data/models.dart' show VenueListItem;
import '../../state/partner_session.dart';
import '../../ui/ui.dart';

/// Create / edit a partner event. Pops with the saved [PartnerEvent].
class PartnerEventFormScreen extends StatefulWidget {
  const PartnerEventFormScreen({super.key, required this.venues, this.event, this.initialVenueId});

  /// Live venues the partner owns (only those can host).
  final List<VenueListItem> venues;

  /// Editing this event when set.
  final PartnerEvent? event;
  final String? initialVenueId;

  @override
  State<PartnerEventFormScreen> createState() => _PartnerEventFormScreenState();
}

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

class _PartnerEventFormScreenState extends State<PartnerEventFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.event?.title);
  late final _description = TextEditingController(text: widget.event?.description);
  late final _reward = TextEditingController(text: widget.event?.reward);
  late final _sponsor = TextEditingController(text: widget.event?.sponsor);

  late String? _venueId;
  late EventFormat _format = widget.event?.format ?? EventFormat.virtual;
  late String _metric = widget.event != null && ['checkins', 'running_km', 'streak'].contains(widget.event!.metric)
      ? widget.event!.metric
      : 'checkins';
  late String _exercise = widget.event?.arenaExercise ?? 'pushups';
  late bool _membersOnly = widget.event?.membersOnly ?? false;
  late DateTime _startsOn = widget.event?.startsOn ?? _today();
  late DateTime _endsOn = widget.event?.endsOn ?? _today().add(const Duration(days: 29));
  late DateTime _eventDate = widget.event?.eventDate ?? _today().add(const Duration(days: 7));
  String? _coverUrl;
  bool _uploading = false;
  bool _saving = false;

  bool get _editing => widget.event != null;

  @override
  void initState() {
    super.initState();
    _coverUrl = widget.event?.coverUrl;
    final ids = widget.venues.map((v) => v.id).toSet();
    final wanted = widget.event?.venue.id ?? widget.initialVenueId;
    _venueId = wanted != null && ids.contains(wanted) ? wanted : (widget.venues.isEmpty ? null : widget.venues.first.id);
    if (_eventDate.isBefore(_today())) _eventDate = _today();
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _reward.dispose();
    _sponsor.dispose();
    super.dispose();
  }

  VenueListItem? get _venue => widget.venues.where((v) => v.id == _venueId).firstOrNull;

  Future<void> _pickCover() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 80);
    if (f == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final url = await context.read<PartnerSession>().api.upload(f);
      if (mounted) setState(() => _coverUrl = url);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickRange() async {
    final first = _startsOn.isBefore(_today()) ? _startsOn : _today();
    final r = await showDateRangePicker(
      context: context,
      firstDate: first,
      lastDate: _today().add(const Duration(days: 365)),
      initialDateRange: DateTimeRange(start: _startsOn, end: _endsOn.isBefore(_startsOn) ? _startsOn : _endsOn),
      helpText: 'When does the event run?',
    );
    if (r != null && mounted) {
      setState(() {
        _startsOn = r.start;
        _endsOn = r.end;
      });
    }
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      firstDate: _today(),
      lastDate: _today().add(const Duration(days: 365)),
      initialDate: _eventDate.isBefore(_today()) ? _today() : _eventDate,
      helpText: 'Event day',
    );
    if (d != null && mounted) setState(() => _eventDate = d);
  }

  String? _opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Map<String, dynamic> _payload() {
    final m = <String, dynamic>{
      'title': _title.text.trim(),
      'description': _opt(_description),
      'venueId': _venueId,
      'format': _format.name,
      'membersOnly': _membersOnly,
      'reward': _opt(_reward),
      'sponsor': _opt(_sponsor),
      'coverUrl': _coverUrl,
    };
    switch (_format) {
      case EventFormat.onground:
        // Registration opens now (or keeps its original start) and closes on the event day.
        final start = widget.event?.startsOn ?? _today();
        m['eventDate'] = apiDate(_eventDate);
        m['startsOn'] = apiDate(start.isAfter(_eventDate) ? _today() : start);
        m['endsOn'] = apiDate(_eventDate);
      case EventFormat.ai:
        m['arenaExercise'] = _exercise;
        m['startsOn'] = apiDate(_startsOn);
        m['endsOn'] = apiDate(_endsOn);
      case EventFormat.virtual:
        m['metric'] = _metric;
        m['startsOn'] = apiDate(_startsOn);
        m['endsOn'] = apiDate(_endsOn);
    }
    return m;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_venueId == null) {
      toast(context, 'Choose the venue hosting this event', error: true);
      return;
    }
    setState(() => _saving = true);
    final api = context.read<PartnerSession>().api;
    try {
      if (_editing) {
        final r = await api.updatePartnerEvent(widget.event!.id, _payload());
        if (!mounted) return;
        toast(context, r.notified > 0 ? 'Saved · ${r.notified} registered member${r.notified == 1 ? '' : 's'} notified' : 'Event saved');
        Navigator.of(context).pop(r.event);
      } else {
        final e = await api.createPartnerEvent(_payload());
        if (!mounted) return;
        toast(context, 'Event published — members can join now');
        Navigator.of(context).pop(e);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final venue = _venue;
    final fallback = venueVisual(venue?.categories.firstOrNull ?? 'gym').image;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(_editing ? 'Edit event' : 'New event')),
      bottomNavigationBar: BottomActionBar(
        child: AppButton(
          label: _editing ? 'Save changes' : 'Publish event',
          icon: _editing ? Icons.check_rounded : Icons.rocket_launch_rounded,
          busy: _saving,
          onPressed: _uploading ? null : _save,
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            // Cover
            Tap(
              onTap: _uploading ? null : _pickCover,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: SizedBox(
                  height: 170,
                  child: Stack(fit: StackFit.expand, children: [
                    NetImage(_coverUrl ?? venue?.coverPhoto, fallback: fallback),
                    const PhotoScrim(strength: 0.7),
                    Center(
                      child: _uploading
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.add_photo_alternate_rounded, size: 18, color: AppColors.ink),
                                const SizedBox(width: 6),
                                Text(_coverUrl == null ? 'Add cover photo' : 'Change cover',
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: AppColors.ink)),
                              ]),
                            ),
                    ),
                    if (_coverUrl != null && !_uploading)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: IconButton.filled(
                          style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppColors.ink),
                          tooltip: 'Remove cover',
                          onPressed: () => setState(() => _coverUrl = null),
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text('No cover? We\'ll use your venue photo.',
                style: TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
            const SectionTitle('Basics', padding: EdgeInsets.fromLTRB(0, 20, 0, 12)),
            TextFormField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 160,
              decoration: const InputDecoration(labelText: 'Event title', hintText: 'e.g. 30-Day Shred Challenge', counterText: ''),
              validator: (v) => (v ?? '').trim().length < 3 ? 'Give your event a title (3+ characters)' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _description,
              minLines: 3,
              maxLines: 6,
              maxLength: 4000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'What happens, what to bring, how winners are picked…',
                alignLabelWithHint: true,
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _venueId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Host venue'),
              items: [
                for (final v in widget.venues)
                  DropdownMenuItem(
                    value: v.id,
                    child: Text(v.location.isEmpty ? v.name : '${v.name} · ${v.location}', overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _venueId = v),
              validator: (v) => v == null ? 'Choose a venue' : null,
            ),
            const SectionTitle('Format', padding: EdgeInsets.fromLTRB(0, 22, 0, 12)),
            for (final f in EventFormat.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _OptionCard(
                  selected: _format == f,
                  icon: switch (f) {
                    EventFormat.virtual => Icons.public_rounded,
                    EventFormat.onground => Icons.place_rounded,
                    EventFormat.ai => Icons.auto_awesome_rounded,
                  },
                  title: f.label,
                  subtitle: f.blurb,
                  onTap: () => setState(() => _format = f),
                ),
              ),
            if (_format == EventFormat.virtual) ...[
              const SizedBox(height: 4),
              const Text('Rank members by', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              ChoiceChips<String>(
                padding: EdgeInsets.zero,
                options: const ['checkins', 'running_km', 'streak'],
                selected: _metric,
                onSelected: (m) => setState(() => _metric = m),
                label: (m) => eventMetricLabels[m]!,
              ),
            ],
            if (_format == EventFormat.ai) ...[
              const SizedBox(height: 4),
              const Text('Exercise (counted by the AI camera)', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              ChoiceChips<String>(
                padding: EdgeInsets.zero,
                options: arenaExercises.keys.toList(),
                selected: _exercise,
                onSelected: (x) => setState(() => _exercise = x),
                label: (x) => arenaExercises[x]!,
              ),
            ],
            const SectionTitle('When', padding: EdgeInsets.fromLTRB(0, 22, 0, 12)),
            AppCard(
              onTap: _format == EventFormat.onground ? _pickDay : _pickRange,
              child: Row(children: [
                const IconBubble(Icons.calendar_month_rounded, color: AppColors.blue),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_format == EventFormat.onground ? 'Event day' : 'Runs',
                        style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      _format == EventFormat.onground
                          ? formatDayDate(_eventDate)
                          : '${formatShortDate(_startsOn)} – ${formatShortDate(_endsOn)} · '
                              '${_endsOn.difference(_startsOn).inDays + 1} days',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                  ]),
                ),
                const Icon(Icons.edit_calendar_rounded, color: AppColors.text3),
              ]),
            ),
            if (_format == EventFormat.onground)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Members register until the event day and check in with your front-desk QR to be marked attended.',
                    style: TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
              ),
            const SectionTitle('Who can join', padding: EdgeInsets.fromLTRB(0, 22, 0, 12)),
            AppCard(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _membersOnly,
                onChanged: (v) => setState(() => _membersOnly = v),
                title: const Text('Members only', style: TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(
                  _membersOnly
                      ? 'Only people who have checked in at ${venue?.name ?? 'your venue'} or hold a plan covering it.'
                      : 'Anyone on FitKey can join — great for bringing in new members.',
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                ),
              ),
            ),
            const SectionTitle('Extras', subtitle: 'Optional', padding: EdgeInsets.fromLTRB(0, 22, 0, 12)),
            TextFormField(
              controller: _reward,
              maxLength: 200,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reward',
                hintText: 'e.g. 1 month free membership for the top 3',
                prefixIcon: Icon(Icons.card_giftcard_rounded),
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _sponsor,
              maxLength: 120,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Sponsor',
                hintText: 'e.g. MuscleBlaze',
                prefixIcon: Icon(Icons.handshake_rounded),
                counterText: '',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({required this.selected, required this.icon, required this.title, required this.subtitle, required this.onTap});
  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primarySoft : AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? AppColors.primary : AppColors.line, width: selected ? 1.6 : 1),
        ),
        child: Row(children: [
          IconBubble(icon, color: selected ? AppColors.primary : AppColors.text2, bg: selected ? AppColors.surface : null),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
            ]),
          ),
          Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              color: selected ? AppColors.primary : AppColors.text3),
        ]),
      ),
    );
  }
}
