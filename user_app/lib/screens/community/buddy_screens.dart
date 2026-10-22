import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart' show apiDate, formatClock, formatDayDate, formatShortDate, formatTimeOfDay;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';

String _slot(String start, String end) => '${formatTimeOfDay(start)} – ${formatTimeOfDay(end)}';

String _relativeDay(DateTime d) {
  final today = DateUtils.dateOnly(DateTime.now());
  final day = DateUtils.dateOnly(d);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  return formatDayDate(d);
}

// ===========================================================================
// U6 — Gym buddy tab
// Post a venue + time slot → see others with an overlapping slot → both opt in → chat.
// ===========================================================================

class BuddyTab extends StatefulWidget {
  const BuddyTab({super.key});

  @override
  State<BuddyTab> createState() => _BuddyTabState();
}

typedef _BuddyData = (List<BuddyPost>, List<BuddyRequest>);

class _BuddyTabState extends State<BuddyTab> with AutomaticKeepAliveClientMixin {
  late Future<_BuddyData> _future;
  final _busy = <String>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_BuddyData> _load() async {
    final api = context.read<Session>().api;
    final r = await Future.wait([api.myBuddyPosts(), api.buddyRequests()]);
    return (r[0] as List<BuddyPost>, r[1] as List<BuddyRequest>);
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* shown by the FutureBuilder */}
  }

  Future<void> _respond(BuddyRequest r, bool accept) async {
    setState(() => _busy.add(r.id));
    try {
      await context.read<Session>().api.respondBuddyRequest(r.id, accept: accept);
      if (!mounted) return;
      toast(context, accept ? "You're buddies with ${r.otherName ?? 'this member'}! Say hi 👋" : 'Request declined',
          icon: accept ? Icons.handshake_rounded : Icons.close_rounded);
      await _reload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(r.id));
    }
  }

  Future<void> _go(Widget screen) async {
    await push(context, screen);
    if (mounted) _reload();
  }

  Future<void> _newPost() => _go(const CreateBuddyPostScreen());

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: AppColors.bg,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'buddy-fab',
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 2,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Plan a session', style: TextStyle(fontWeight: FontWeight.w800)),
        onPressed: _newPost,
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
          children: [
            PhotoBanner(
              image: AppImages.battleRopes,
              eyebrow: 'Gym buddy',
              title: 'Never train alone again',
              subtitle: 'Match with members at the same venue & time.',
              cta: 'Plan a session',
              height: 160,
              onTap: _newPost,
            ),
            FutureBuilder<_BuddyData>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const SkeletonList(count: 3, itemHeight: 72, padding: EdgeInsets.only(top: 24));
                }
                if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
                return _content(snap.data!);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(_BuddyData data) {
    final (posts, requests) = data;
    final incoming = requests.where((r) => r.status == 'pending' && r.direction == 'incoming').toList();
    final buddies = requests.where((r) => r.status == 'accepted').toList();
    final outgoing = requests.where((r) => r.status == 'pending' && r.direction == 'outgoing').toList();

    if (posts.isEmpty && requests.isEmpty) {
      return Column(children: [
        EmptyView(
          icon: Icons.people_alt_rounded,
          color: AppColors.teal,
          title: 'Find your workout partner',
          message: "Tell us where and when you're training. We'll show members going at the same time.",
          action: SizedBox(
            width: 220,
            child: AppButton(label: 'Plan a session', icon: Icons.add_rounded, height: 48, onPressed: _newPost),
          ),
        ),
        const _SafetyNote(),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (incoming.isNotEmpty) ...[
        SectionTitle('Requests for you', subtitle: '${incoming.length} member${incoming.length == 1 ? '' : 's'} want to train with you'),
        for (final r in incoming)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _IncomingCard(
              request: r,
              busy: _busy.contains(r.id),
              onAccept: () => _respond(r, true),
              onDecline: () => _respond(r, false),
            ),
          ),
      ],
      if (buddies.isNotEmpty) ...[
        const SectionTitle('Chats', subtitle: 'Your confirmed gym buddies'),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (var i = 0; i < buddies.length; i++) ...[
              if (i > 0) const Divider(indent: 76),
              _ChatRow(request: buddies[i], onTap: () => _go(BuddyChatScreen(request: buddies[i]))),
            ],
          ]),
        ),
      ],
      if (posts.isNotEmpty) ...[
        const SectionTitle('Your sessions', subtitle: 'Tap a session to see who else is going'),
        for (final p in posts)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _PostCard(post: p, onTap: () => _go(BuddyMatchesScreen(post: p))),
          ),
      ],
      if (outgoing.isNotEmpty) ...[
        const SectionTitle('Waiting for reply'),
        for (final r in outgoing)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: AppCard(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                PersonAvatar(name: r.otherName, size: 46),
                const SizedBox(width: 12),
                Expanded(child: _PersonLines(request: r)),
                const Tag('PENDING', icon: Icons.hourglass_top_rounded, color: AppColors.amber, dense: true),
              ]),
            ),
          ),
      ],
      const SizedBox(height: 12),
      const _SafetyNote(),
    ]);
  }
}

class _PersonLines extends StatelessWidget {
  const _PersonLines({required this.request});
  final BuddyRequest request;

  @override
  Widget build(BuildContext context) {
    final r = request;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(r.otherName ?? 'FITKEY member',
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      const SizedBox(height: 2),
      Text(r.venueName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
      Text('${_relativeDay(r.slotDate)} · ${_slot(r.slotStart, r.slotEnd)}',
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AppColors.text3)),
    ]);
  }
}

class _IncomingCard extends StatelessWidget {
  const _IncomingCard({required this.request, required this.busy, required this.onAccept, required this.onDecline});
  final BuddyRequest request;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    const small = Size(0, 44);
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(children: [
        Row(children: [
          PersonAvatar(name: request.otherName, size: 50),
          const SizedBox(width: 12),
          Expanded(child: _PersonLines(request: request)),
          const Tag('NEW', color: AppColors.primary, dense: true),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: small),
              onPressed: busy ? null : onDecline,
              child: const Text('Decline'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: small, backgroundColor: AppColors.green),
              onPressed: busy ? null : onAccept,
              icon: busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_rounded, size: 18),
              label: const Text('Accept', style: TextStyle(fontSize: 14.5)),
            ),
          ),
        ]),
      ]),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({required this.request, required this.onTap});
  final BuddyRequest request;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final last = r.lastMessage;
    return Tap(
      onTap: onTap,
      scale: 0.99,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(children: [
          PersonAvatar(name: r.otherName, size: 50),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(r.otherName ?? 'FITKEY member',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                ),
                Text(_relativeDay(r.slotDate),
                    style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 3),
              Text(
                last == null || last.isEmpty ? "You're buddies now — say hi 👋" : last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: last == null ? AppColors.primary : AppColors.text2,
                  fontWeight: last == null ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text('${r.venueName} · ${formatTimeOfDay(r.slotStart)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
            ]),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
        ]),
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({required this.post, required this.onTap});
  final BuddyPost post;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = post;
    final matched = p.matchCount > 0;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _DateBlock(date: p.slotDate),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.venueName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
            if (p.venueArea != null)
              Text(p.venueArea!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.schedule_rounded, size: 15, color: AppColors.text2),
              const SizedBox(width: 4),
              Text('${_relativeDay(p.slotDate)} · ${_slot(p.slotStart, p.slotEnd)}',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w700)),
            ]),
            if (p.note != null && p.note!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('“${p.note}”',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontStyle: FontStyle.italic, color: AppColors.text2)),
            ],
            const SizedBox(height: 10),
            Row(children: [
              matched
                  ? Tag('${p.matchCount} MATCH${p.matchCount == 1 ? '' : 'ES'}',
                      icon: Icons.people_alt_rounded, color: AppColors.green, dense: true)
                  : const Tag('LOOKING FOR BUDDIES', icon: Icons.search_rounded, color: AppColors.text2, dense: true),
              const Spacer(),
              Text(matched ? 'View' : 'Details',
                  style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 13)),
              const Icon(Icons.chevron_right_rounded, color: AppColors.primary, size: 18),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _DateBlock extends StatelessWidget {
  const _DateBlock({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 58,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(color: AppColors.tealSoft, borderRadius: BorderRadius.circular(14)),
      child: Column(children: [
        Text(DateFormat('EEE').format(date).toUpperCase(),
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.teal, letterSpacing: 0.8)),
        Text('${date.day}',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.text, height: 1.15)),
        Text(DateFormat('MMM').format(date),
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.text2)),
      ]),
    );
  }
}

class _SafetyNote extends StatelessWidget {
  const _SafetyNote();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      color: AppColors.blueSoft,
      shadow: false,
      padding: const EdgeInsets.all(14),
      child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconBubble(Icons.shield_rounded, color: AppColors.blue, bg: Colors.white, size: 36),
        SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Train safe', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            SizedBox(height: 2),
            Text(
              'Meet only at the venue and never share your home address. '
              'You can block or report anyone from the chat menu.',
              style: TextStyle(fontSize: 12.5, color: AppColors.text2, height: 1.45),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Plan a session
// ===========================================================================

class CreateBuddyPostScreen extends StatefulWidget {
  const CreateBuddyPostScreen({super.key, this.initialVenue});

  final VenueSummary? initialVenue;

  @override
  State<CreateBuddyPostScreen> createState() => _CreateBuddyPostScreenState();
}

class _CreateBuddyPostScreenState extends State<CreateBuddyPostScreen> {
  static const _days = 14;
  static const _presets = [(6, 7), (7, 8), (8, 9), (17, 18), (18, 19), (19, 20), (20, 21)];

  VenueSummary? _venue;
  late DateTime _date;
  TimeOfDay _start = const TimeOfDay(hour: 7, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 8, minute: 0);
  final _note = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _venue = widget.initialVenue;
    _date = DateUtils.dateOnly(DateTime.now());
    final now = TimeOfDay.now();
    if (now.hour < 22) {
      _start = TimeOfDay(hour: now.hour + 1, minute: 0);
      _end = TimeOfDay(hour: now.hour + 2 > 23 ? 23 : now.hour + 2, minute: 0);
    } else {
      _date = _date.add(const Duration(days: 1));
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;
  bool get _isToday => DateUtils.isSameDay(_date, DateTime.now());
  bool _past(int endHour) => _isToday && endHour * 60 <= _minutes(TimeOfDay.now());

  Future<void> _pickVenue() async {
    final v = await showAppSheet<VenueSummary>(context, builder: (_) => const _VenuePickerSheet());
    if (v != null && mounted) setState(() => _venue = v);
  }

  Future<void> _pickTime(bool start) async {
    final t = await showTimePicker(context: context, initialTime: start ? _start : _end);
    if (t == null || !mounted) return;
    setState(() {
      if (start) {
        _start = t;
        if (_minutes(_end) <= _minutes(t)) _end = TimeOfDay(hour: (t.hour + 1).clamp(0, 23), minute: t.minute);
      } else {
        _end = t;
      }
    });
  }

  Future<void> _save() async {
    if (_venue == null) {
      toast(context, 'Pick a venue first', error: true);
      return;
    }
    if (_minutes(_end) <= _minutes(_start)) {
      toast(context, 'End time must be after start time', error: true);
      return;
    }
    if (_isToday && _minutes(_end) <= _minutes(TimeOfDay.now())) {
      toast(context, 'That slot is already over — pick a later time', error: true);
      return;
    }
    setState(() => _saving = true);
    final api = context.read<Session>().api;
    try {
      final postId = await api.createBuddyPost(
        venueId: _venue!.id,
        slotDate: apiDate(_date),
        slotStart: _hhmm(_start),
        slotEnd: _hhmm(_end),
        note: _note.text.trim(),
      );
      final posts = await api.myBuddyPosts();
      if (!mounted) return;
      final post = posts.where((p) => p.id == postId).firstOrNull;
      if (post != null) {
        await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => BuddyMatchesScreen(post: post)));
      } else {
        toast(context, 'Session posted');
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        toast(context, friendlyError(e), error: true);
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Plan a session')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          AppCard(
            gradient: const LinearGradient(
              colors: [Color(0xFF14B8A6), Color(0xFF0E9F6E)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shadow: false,
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Find a gym buddy',
                      style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                  const SizedBox(height: 4),
                  Text("Tell us where and when you're training — we'll match you with members going at the same time.",
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.88), fontSize: 13, height: 1.4)),
                ]),
              ),
              const SizedBox(width: 10),
              Icon(Icons.people_alt_rounded, size: 52, color: Colors.white.withValues(alpha: 0.85)),
            ]),
          ),
          const SectionTitle('Where', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
          _VenueField(venue: _venue, onTap: _pickVenue),
          const SectionTitle('When', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
          SizedBox(
            height: 78,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: _days,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final d = today.add(Duration(days: i));
                final on = DateUtils.isSameDay(d, _date);
                return Tap(
                  onTap: () => setState(() => _date = d),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 60,
                    decoration: BoxDecoration(
                      color: on ? AppColors.ink : AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: on ? AppColors.ink : AppColors.line),
                    ),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(i == 0 ? 'Today' : (i == 1 ? 'Tmrw' : DateFormat('EEE').format(d)),
                          style: TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w700, color: on ? Colors.white70 : AppColors.text3)),
                      const SizedBox(height: 2),
                      Text('${d.day}',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on ? Colors.white : AppColors.text)),
                      Text(DateFormat('MMM').format(d),
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w600, color: on ? Colors.white70 : AppColors.text2)),
                    ]),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _TimeField(label: 'From', value: _start.format(context), onTap: () => _pickTime(true))),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.arrow_forward_rounded, color: AppColors.text3, size: 20),
            ),
            Expanded(child: _TimeField(label: 'To', value: _end.format(context), onTap: () => _pickTime(false))),
          ]),
          const SizedBox(height: 12),
          const Text('Quick slots', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.text2)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (s, e) in _presets)
              _PresetChip(
                label: '${_h(s)}–${_h(e)}',
                selected: _start == TimeOfDay(hour: s, minute: 0) && _end == TimeOfDay(hour: e, minute: 0),
                enabled: !_past(e),
                onTap: () => setState(() {
                  _start = TimeOfDay(hour: s, minute: 0);
                  _end = TimeOfDay(hour: e, minute: 0);
                }),
              ),
          ]),
          const SectionTitle('Add a note', subtitle: 'Optional — helps buddies know what to expect',
              padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
          TextField(
            controller: _note,
            maxLength: 280,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'e.g. "Leg day, need a spotter"'),
          ),
        ],
      ),
      bottomNavigationBar: BottomActionBar(
        child: AppButton(
          label: _saving ? 'Finding buddies…' : 'Find buddies',
          icon: Icons.search_rounded,
          busy: _saving,
          onPressed: _save,
        ),
      ),
    );
  }

  static String _h(int hour) {
    final h12 = hour % 12 == 0 ? 12 : hour % 12;
    return '$h12 ${hour < 12 ? 'AM' : 'PM'}';
  }
}

class _VenueField extends StatelessWidget {
  const _VenueField({required this.venue, required this.onTap});
  final VenueSummary? venue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = venue;
    if (v == null) {
      return AppCard(
        onTap: onTap,
        child: const Row(children: [
          IconBubble(Icons.storefront_rounded, color: AppColors.primary, size: 48),
          SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Choose a venue', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
              SizedBox(height: 2),
              Text('Search gyms, pools & studios',
                  style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w500)),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: AppColors.text3),
        ]),
      );
    }
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        NetImage(v.coverPhoto,
            fallback: venueVisual(v.categories.isEmpty ? 'gym' : v.categories.first).image, width: 64, height: 64, radius: 14),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(v.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
            if (v.location.isNotEmpty)
              Text(v.location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w500)),
          ]),
        ),
        const Text('Change', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 13)),
      ]),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({required this.label, required this.value, required this.onTap});
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      radius: 16,
      child: Row(children: [
        const Icon(Icons.schedule_rounded, color: AppColors.primary, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w700)),
            Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ]),
        ),
      ]),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({required this.label, required this.selected, required this.enabled, required this.onTap});
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.primarySoft : (enabled ? AppColors.surface : AppColors.surfaceAlt),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? AppColors.primary : AppColors.line),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: selected ? AppColors.primary : (enabled ? AppColors.text : AppColors.text3),
              decoration: enabled ? null : TextDecoration.lineThrough,
            )),
      ),
    );
  }
}

/// Searchable venue list (debounced) shown as a bottom sheet.
class _VenuePickerSheet extends StatefulWidget {
  const _VenuePickerSheet();

  @override
  State<_VenuePickerSheet> createState() => _VenuePickerSheetState();
}

class _VenuePickerSheetState extends State<_VenuePickerSheet> {
  final _search = TextEditingController();
  Timer? _debounce;
  late Future<List<VenueSummary>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load('');
  }

  Future<List<VenueSummary>> _load(String q) =>
      context.read<Session>().api.venues(q: q.isEmpty ? null : q, limit: 30);

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _future = _load(v.trim()));
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text('Choose a venue', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: RotatingSearchBar(
            hints: const ["'gym name'", "'area'", "'swimming pool'", "'yoga studio'"],
            controller: _search,
            onChanged: _onChanged,
            onSubmitted: (v) {
              _debounce?.cancel();
              setState(() => _future = _load(v.trim()));
            },
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: FutureBuilder<List<VenueSummary>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 5, itemHeight: 56);
              if (snap.hasError) {
                return ErrorView(
                  error: snap.error!,
                  onRetry: () => setState(() => _future = _load(_search.text.trim())),
                );
              }
              final venues = snap.data!;
              if (venues.isEmpty) {
                return const EmptyView(
                  icon: Icons.search_off_rounded,
                  title: 'No venues found',
                  message: 'Try a different name or area.',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: venues.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final v = venues[i];
                  final cat = venueVisual(v.categories.isEmpty ? 'gym' : v.categories.first);
                  return AppCard(
                    onTap: () => Navigator.pop(context, v),
                    padding: const EdgeInsets.all(10),
                    radius: 16,
                    shadow: false,
                    border: true,
                    child: Row(children: [
                      NetImage(v.coverPhoto, fallback: cat.image, width: 56, height: 56, radius: 12),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(v.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                          if (v.location.isNotEmpty)
                            Text(v.location,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5, color: AppColors.text2)),
                          const SizedBox(height: 4),
                          Tag(cat.label, icon: cat.icon, color: cat.color, dense: true),
                        ]),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
                    ]),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}

// ===========================================================================
// Matches for a session
// ===========================================================================

class BuddyMatchesScreen extends StatefulWidget {
  const BuddyMatchesScreen({super.key, required this.post});

  final BuddyPost post;

  @override
  State<BuddyMatchesScreen> createState() => _BuddyMatchesScreenState();
}

class _BuddyMatchesScreenState extends State<BuddyMatchesScreen> {
  late Future<List<BuddyMatch>> _future;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<BuddyMatch>> _load() => context.read<Session>().api.buddyMatches(widget.post.id);

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* shown by the FutureBuilder */}
  }

  Future<void> _run(String key, Future<void> Function() action) async {
    setState(() => _busy.add(key));
    try {
      await action();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _request(BuddyMatch m) => _run(m.postId, () async {
        await context.read<Session>().api.sendBuddyRequest(widget.post.id, m.postId);
        if (!mounted) return;
        toast(context, 'Request sent to ${m.name ?? 'member'}', icon: Icons.send_rounded);
        await _reload();
      });

  Future<void> _accept(BuddyMatch m) => _run(m.postId, () async {
        await context.read<Session>().api.respondBuddyRequest(m.requestId!, accept: true);
        if (!mounted) return;
        toast(context, "You're buddies with ${m.name ?? 'this member'}!", icon: Icons.handshake_rounded);
        await _reload();
      });

  Future<void> _openChat(BuddyMatch m) => _run(m.postId, () async {
        final requests = await context.read<Session>().api.buddyRequests();
        if (!mounted) return;
        final r = requests.where((r) => r.id == m.requestId).firstOrNull;
        if (r == null) {
          toast(context, 'This chat is no longer available', error: true);
          return;
        }
        await push(context, BuddyChatScreen(request: r));
        if (mounted) _reload();
      });

  Future<void> _deletePost() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this session?'),
        content: const Text('Your slot will be removed and pending requests cancelled.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: AppColors.text2),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('Cancel session'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<Session>().api.deleteBuddyPost(widget.post.id);
      if (!mounted) return;
      toast(context, 'Session cancelled');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Buddies for this slot'),
        actions: [
          IconButton(
            tooltip: 'Cancel session',
            icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red),
            onPressed: _deletePost,
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: SizedBox(
                height: 150,
                child: Stack(fit: StackFit.expand, children: [
                  Image.asset(AppImages.gymFloor, fit: BoxFit.cover),
                  const PhotoScrim(strength: 0.85),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(p.venueName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                        if (p.venueArea != null)
                          Text(p.venueArea!,
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontWeight: FontWeight.w600)),
                        const SizedBox(height: 10),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          Tag(_relativeDay(p.slotDate).toUpperCase(),
                              icon: Icons.event_rounded, color: Colors.white, bg: const Color(0x33FFFFFF), dense: true),
                          Tag(_slot(p.slotStart, p.slotEnd),
                              icon: Icons.schedule_rounded, color: Colors.white, bg: const Color(0x33FFFFFF), dense: true),
                        ]),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
            if (p.note != null && p.note!.isNotEmpty) ...[
              const SizedBox(height: 12),
              AppCard(
                padding: const EdgeInsets.all(14),
                shadow: false,
                border: true,
                child: Row(children: [
                  const Icon(Icons.sticky_note_2_outlined, color: AppColors.text3, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text('Your note: “${p.note}”',
                          style: const TextStyle(color: AppColors.text2, fontStyle: FontStyle.italic))),
                ]),
              ),
            ],
            FutureBuilder<List<BuddyMatch>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const SkeletonList(count: 3, itemHeight: 64, padding: EdgeInsets.only(top: 24));
                }
                if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
                final matches = snap.data!;
                if (matches.isEmpty) {
                  return EmptyView(
                    icon: Icons.hourglass_empty_rounded,
                    color: AppColors.teal,
                    title: 'No one yet',
                    message: "We'll keep your slot open. Members who post an overlapping time will show up here.",
                    action: SizedBox(
                      width: 180,
                      child: OutlinedButton.icon(
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Check again'),
                      ),
                    ),
                  );
                }
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SectionTitle('${matches.length} member${matches.length == 1 ? '' : 's'} going',
                      subtitle: 'Overlapping with your slot'),
                  for (final m in matches)
                    Padding(padding: const EdgeInsets.only(bottom: 12), child: _matchCard(m)),
                ]);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _matchCard(BuddyMatch m) {
    final busy = _busy.contains(m.postId);
    const small = Size(0, 40);
    final Widget action = switch ((m.requestStatus, m.requestDirection)) {
      (null, _) => FilledButton(
          style: FilledButton.styleFrom(minimumSize: small, padding: const EdgeInsets.symmetric(horizontal: 16)),
          onPressed: busy ? null : () => _request(m),
          child: busy ? _spinner : const Text('Go together', style: TextStyle(fontSize: 13.5)),
        ),
      ('pending', 'outgoing') => const Tag('REQUESTED', icon: Icons.hourglass_top_rounded, color: AppColors.amber),
      ('pending', 'incoming') => FilledButton(
          style: FilledButton.styleFrom(
              minimumSize: small, backgroundColor: AppColors.green, padding: const EdgeInsets.symmetric(horizontal: 16)),
          onPressed: busy || m.requestId == null ? null : () => _accept(m),
          child: busy ? _spinner : const Text('Accept', style: TextStyle(fontSize: 13.5)),
        ),
      ('accepted', _) => OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: small,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            foregroundColor: AppColors.primary,
            side: const BorderSide(color: AppColors.primary),
          ),
          onPressed: busy || m.requestId == null ? null : () => _openChat(m),
          icon: busy ? _spinner : const Icon(Icons.chat_bubble_rounded, size: 16),
          label: const Text('Chat', style: TextStyle(fontSize: 13.5)),
        ),
      _ => const Tag('DECLINED', color: AppColors.text3),
    };
    final status = switch ((m.requestStatus, m.requestDirection)) {
      ('pending', 'incoming') => const Tag('WANTS TO JOIN YOU', color: AppColors.primary, dense: true),
      ('accepted', _) => const Tag('BUDDIES', icon: Icons.check_rounded, color: AppColors.green, dense: true),
      _ => null,
    };
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          PersonAvatar(name: m.name, size: 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.name ?? 'FITKEY member',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
              const SizedBox(height: 2),
              Row(children: [
                const Icon(Icons.schedule_rounded, size: 14, color: AppColors.text3),
                const SizedBox(width: 4),
                Text(_slot(m.slotStart, m.slotEnd),
                    style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ]),
              if (status != null) ...[const SizedBox(height: 6), status],
            ]),
          ),
          const SizedBox(width: 8),
          action,
        ]),
        if (m.note != null && m.note!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
            child: Text('“${m.note}”',
                style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: AppColors.text2)),
          ),
        ],
      ]),
    );
  }

  static const _spinner = SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
}

// ===========================================================================
// Chat
// ===========================================================================

class BuddyChatScreen extends StatefulWidget {
  const BuddyChatScreen({super.key, required this.request});

  final BuddyRequest request;

  @override
  State<BuddyChatScreen> createState() => _BuddyChatScreenState();
}

class _BuddyChatScreenState extends State<BuddyChatScreen> {
  static const _suggestions = ['Hey! 👋', 'See you at the entrance?', "I'll be there 5 min early", 'What are you training today?'];

  final _messages = <ChatMessage>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _poll;
  bool _loading = true;
  bool _fetching = false;
  bool _sending = false;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInput);
    _fetch();
    // Simple polling keeps Phase 1 free of websockets; swap for a socket/FCM later.
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _fetch());
  }

  void _onInput() => setState(() {});

  @override
  void dispose() {
    _poll?.cancel();
    _poll = null;
    _input.removeListener(_onInput);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    if (_fetching || !mounted) return; // never overlap two polls
    _fetching = true;
    try {
      final after = _messages.isEmpty ? null : _messages.last.rawCreatedAt;
      final fresh = await context.read<Session>().api.messages(widget.request.id, after: after);
      if (!mounted) return;
      final known = _messages.map((m) => m.id).toSet();
      final added = fresh.where((m) => !known.contains(m.id)).toList();
      if (added.isNotEmpty || _loading || _loadError != null) {
        setState(() {
          _messages.addAll(added);
          _loading = false;
          _loadError = null;
        });
      }
    } catch (e) {
      // Background poll failures are silent; only the very first load shows an error.
      if (mounted && _loading) {
        setState(() {
          _loading = false;
          _loadError = e;
        });
      }
    } finally {
      _fetching = false;
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    _fetch();
  }

  void _scrollToLatest() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _sending) return;
    if (preset == null) _input.clear();
    setState(() => _sending = true);
    try {
      final msg = await context.read<Session>().api.sendMessage(widget.request.id, text);
      if (!mounted) return;
      setState(() {
        if (!_messages.any((m) => m.id == msg.id)) _messages.add(msg);
      });
      _scrollToLatest();
    } catch (e) {
      if (!mounted) return;
      if (preset == null && _input.text.isEmpty) _input.text = text; // give the draft back
      toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _menu(String action) async {
    final name = widget.request.otherName ?? 'this member';
    final api = context.read<Session>().api;
    final userId = widget.request.otherUserId;
    if (action == 'block') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.block_rounded, color: AppColors.red, size: 32),
          title: Text('Block $name?'),
          content: const Text("You won't see each other in buddy matches or chats. They won't be notified."),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: TextButton.styleFrom(foregroundColor: AppColors.text2),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: AppColors.red),
              child: const Text('Block'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      try {
        await api.blockUser(userId);
        if (!mounted) return;
        toast(context, '$name has been blocked', icon: Icons.block_rounded);
        Navigator.pop(context);
      } catch (e) {
        if (mounted) toast(context, friendlyError(e), error: true);
      }
    } else {
      final reason = await showDialog<String>(context: context, builder: (_) => _ReportDialog(name: name));
      if (reason == null || reason.length < 3 || !mounted) return;
      try {
        await api.reportUser(userId, reason);
        if (mounted) toast(context, 'Thanks — our team will review this report.', icon: Icons.flag_rounded);
      } catch (e) {
        if (mounted) toast(context, friendlyError(e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return Scaffold(
      backgroundColor: const Color(0xFFF1EFEA),
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          PersonAvatar(name: r.otherName, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.otherName ?? 'FITKEY member',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
              Text('${r.venueName} · ${formatShortDate(r.slotDate)}, ${formatTimeOfDay(r.slotStart)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w500)),
            ]),
          ),
        ]),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: _menu,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            color: AppColors.surface,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'report',
                child: Row(children: [
                  Icon(Icons.flag_outlined, color: AppColors.text2, size: 20),
                  SizedBox(width: 12),
                  Text('Report'),
                ]),
              ),
              PopupMenuItem(
                value: 'block',
                child: Row(children: [
                  Icon(Icons.block_rounded, color: AppColors.red, size: 20),
                  SizedBox(width: 12),
                  Text('Block', style: TextStyle(color: AppColors.red)),
                ]),
              ),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Expanded(child: _body()),
        _composer(),
      ]),
    );
  }

  Widget _body() {
    if (_loading) return const _ChatSkeleton();
    if (_loadError != null) return ErrorView(error: _loadError!, onRetry: _retry);
    if (_messages.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        const _SafetyNote(),
        EmptyView(
          icon: Icons.waving_hand_rounded,
          color: AppColors.amber,
          title: 'Say hi 👋',
          message: 'Agree on when to meet at the venue entrance.',
          action: Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
            for (final s in _suggestions)
              Tap(
                onTap: _sending ? null : () => _send(s),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Text(s, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                ),
              ),
          ]),
        ),
      ]);
    }

    // Build chronological items (date separators + bubbles), then render reversed so the
    // newest message sits at the bottom without manual scrolling.
    final items = <Widget>[
      const Padding(padding: EdgeInsets.only(bottom: 12), child: _SafetyNote()),
    ];
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      final prev = i > 0 ? _messages[i - 1] : null;
      final next = i < _messages.length - 1 ? _messages[i + 1] : null;
      if (prev == null || !DateUtils.isSameDay(prev.createdAt, m.createdAt)) {
        items.add(_DateChip(label: _relativeDay(m.createdAt)));
      }
      final groupedWithNext =
          next != null && next.isMine == m.isMine && DateUtils.isSameDay(next.createdAt, m.createdAt);
      items.add(_Bubble(message: m, tail: !groupedWithNext));
    }
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      itemCount: items.length,
      itemBuilder: (_, i) => items[items.length - 1 - i],
    );
  }

  Widget _composer() {
    final canSend = _input.text.trim().isNotEmpty && !_sending;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: SafeArea(
        top: false,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: TextField(
              controller: _input,
              textCapitalization: TextCapitalization.sentences,
              minLines: 1,
              maxLines: 5,
              maxLength: 1000,
              buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                hintText: 'Message',
                fillColor: AppColors.surfaceAlt,
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          Tap(
            onTap: canSend ? _send : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: canSend ? AppColors.primary : AppColors.line,
                shape: BoxShape.circle,
                boxShadow: canSend ? AppShadows.glow(AppColors.primary) : null,
              ),
              alignment: Alignment.center,
              child: _sending
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                  : Icon(Icons.send_rounded, color: canSend ? Colors.white : AppColors.text3, size: 22),
            ),
          ),
        ]),
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  const _DateChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            boxShadow: AppShadows.soft,
          ),
          child: Text(label,
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.text2)),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.tail});
  final ChatMessage message;

  /// Last bubble in a run from the same sender: gets the pointed corner and extra spacing.
  final bool tail;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final mine = m.isMine;
    const r = Radius.circular(18);
    const tip = Radius.circular(4);
    return Padding(
      padding: EdgeInsets.only(bottom: tail ? 8 : 2, left: mine ? 56 : 0, right: mine ? 0 : 56),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.fromLTRB(13, 8, 10, 6),
          decoration: BoxDecoration(
            color: mine ? AppColors.primary : AppColors.surface,
            borderRadius: BorderRadius.only(
              topLeft: r,
              topRight: r,
              bottomLeft: mine || !tail ? r : tip,
              bottomRight: mine && tail ? tip : r,
            ),
            boxShadow: const [BoxShadow(color: Color(0x0F1A1B25), blurRadius: 4, offset: Offset(0, 1))],
          ),
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 8,
            children: [
              Text(m.body,
                  style: TextStyle(color: mine ? Colors.white : AppColors.text, fontSize: 15, height: 1.35)),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(formatClock(m.createdAt),
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: mine ? Colors.white.withValues(alpha: 0.75) : AppColors.text3)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatSkeleton extends StatelessWidget {
  const _ChatSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget b(bool right, double w) => Align(
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(padding: const EdgeInsets.only(bottom: 10), child: SkeletonBox(height: 40, width: w, radius: 18)),
        );
    return Shimmer(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
          b(false, 180),
          b(true, 220),
          b(true, 140),
          b(false, 200),
          b(true, 160),
        ]),
      ),
    );
  }
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.name});
  final String name;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  static const _reasons = ['Inappropriate messages', 'Harassment', 'Spam or scam', 'Fake profile', 'Did not show up'];
  final _c = TextEditingController();

  @override
  void initState() {
    super.initState();
    _c.addListener(_onText);
  }

  void _onText() => setState(() {});

  @override
  void dispose() {
    _c.removeListener(_onText);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _c.text.trim().length >= 3;
    return AlertDialog(
      title: Text('Report ${widget.name}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('What happened? Reports are confidential.', style: TextStyle(color: AppColors.text2)),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final r in _reasons)
              Tap(
                onTap: () => _c.text = r,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _c.text == r ? AppColors.primarySoft : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _c.text == r ? AppColors.primary : Colors.transparent),
                  ),
                  child: Text(r,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: _c.text == r ? AppColors.primary : AppColors.text)),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _c,
            maxLines: 3,
            maxLength: 500,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Add details (optional if you picked a reason)'),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: AppColors.text2),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: valid ? () => Navigator.pop(context, _c.text.trim()) : null,
          style: TextButton.styleFrom(foregroundColor: AppColors.red),
          child: const Text('Report'),
        ),
      ],
    );
  }
}
