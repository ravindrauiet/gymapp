import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import '../checkin/checkin_screen.dart' show pickVenue;

/// U6 — Find your gym buddy.
/// Post a venue + time slot → see others with an overlapping slot → both opt in → chat.
class BuddyTab extends StatefulWidget {
  const BuddyTab({super.key});

  @override
  State<BuddyTab> createState() => _BuddyTabState();
}

class _BuddyTabState extends State<BuddyTab> {
  late Future<(List<BuddyPost>, List<BuddyRequest>)> _future = _load();

  Future<(List<BuddyPost>, List<BuddyRequest>)> _load() async {
    final api = context.read<Session>().api;
    final r = await Future.wait([api.myBuddyPosts(), api.buddyRequests()]);
    return (r[0] as List<BuddyPost>, r[1] as List<BuddyRequest>);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _respond(BuddyRequest r, bool accept) async {
    try {
      await context.read<Session>().api.respondBuddyRequest(r.id, accept: accept);
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  Future<void> _newPost() async {
    final created = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const CreateBuddyPostScreen()));
    if (created == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'buddy-fab',
        backgroundColor: FkColors.lime,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text('Plan a session', style: TextStyle(fontWeight: FontWeight.w800)),
        onPressed: _newPost,
      ),
      body: AsyncView<(List<BuddyPost>, List<BuddyRequest>)>(
        future: _future,
        onRetry: _reload,
        builder: (context, data) {
          final (posts, requests) = data;
          final incoming = requests.where((r) => r.status == 'pending' && r.direction == 'incoming').toList();
          final buddies = requests.where((r) => r.status == 'accepted').toList();
          final outgoing = requests.where((r) => r.status == 'pending' && r.direction == 'outgoing').toList();

          if (posts.isEmpty && requests.isEmpty) {
            return EmptyState(
              icon: Icons.people_alt_outlined,
              title: 'Never work out alone',
              message: 'Tell us where and when you\'re training. We\'ll show members going at the same time.',
              action: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
                onPressed: _newPost,
                child: const Text('Plan a session'),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _future;
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 100),
              children: [
                if (incoming.isNotEmpty) ...[
                  const SectionHeader('Requests for you'),
                  ...incoming.map((r) => _RequestCard(
                        request: r,
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton.filledTonal(
                              onPressed: () => _respond(r, false), icon: const Icon(Icons.close)),
                          const SizedBox(width: 6),
                          IconButton.filled(
                            style: IconButton.styleFrom(backgroundColor: FkColors.lime, foregroundColor: Colors.black),
                            onPressed: () => _respond(r, true),
                            icon: const Icon(Icons.check),
                          ),
                        ]),
                      )),
                ],
                if (buddies.isNotEmpty) ...[
                  const SectionHeader('Your buddies'),
                  ...buddies.map((r) => _RequestCard(
                        request: r,
                        subtitle: r.lastMessage,
                        trailing: const Icon(Icons.chat_bubble_outline, color: FkColors.lime),
                        onTap: () async {
                          await Navigator.push(context, MaterialPageRoute(builder: (_) => BuddyChatScreen(request: r)));
                          _reload();
                        },
                      )),
                ],
                if (posts.isNotEmpty) ...[
                  const SectionHeader('Your upcoming sessions'),
                  ...posts.map((p) => Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                          title: Text(p.venueName, style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            '${formatDayDate(p.slotDate)} · ${formatTimeOfDay(p.slotStart)} – ${formatTimeOfDay(p.slotEnd)}',
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: (p.matchCount > 0 ? FkColors.lime : FkColors.surfaceHigh).withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              p.matchCount == 0 ? 'No matches yet' : '${p.matchCount} going',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: p.matchCount > 0 ? FkColors.lime : FkColors.textSecondary,
                              ),
                            ),
                          ),
                          onTap: () async {
                            await Navigator.push(
                                context, MaterialPageRoute(builder: (_) => BuddyMatchesScreen(post: p)));
                            _reload();
                          },
                        ),
                      )),
                ],
                if (outgoing.isNotEmpty) ...[
                  const SectionHeader('Waiting for reply'),
                  ...outgoing.map((r) => _RequestCard(
                        request: r,
                        trailing: const Text('Pending', style: TextStyle(color: FkColors.textSecondary)),
                      )),
                ],
                const SizedBox(height: 8),
                const _SafetyNote(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request, required this.trailing, this.subtitle, this.onTap});

  final BuddyRequest request;
  final Widget trailing;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        leading: Avatar(name: request.otherName),
        title: Text(request.otherName ?? 'FITKEY member', style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          subtitle ??
              '${request.venueName} · ${formatDayDate(request.slotDate)}, ${formatTimeOfDay(request.slotStart)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: trailing,
      ),
    );
  }
}

class _SafetyNote extends StatelessWidget {
  const _SafetyNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: FkColors.surface, borderRadius: BorderRadius.circular(14)),
      child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.shield_outlined, color: FkColors.sky, size: 20),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Stay safe: meet only at the venue, and never share your home address. '
            'You can block or report anyone from the chat menu.',
            style: TextStyle(fontSize: 12, color: FkColors.textSecondary, height: 1.4),
          ),
        ),
      ]),
    );
  }
}

class CreateBuddyPostScreen extends StatefulWidget {
  const CreateBuddyPostScreen({super.key, this.initialVenue});

  final VenueSummary? initialVenue;

  @override
  State<CreateBuddyPostScreen> createState() => _CreateBuddyPostScreenState();
}

class _CreateBuddyPostScreenState extends State<CreateBuddyPostScreen> {
  VenueSummary? _venue;
  DateTime _date = DateTime.now();
  TimeOfDay _start = const TimeOfDay(hour: 7, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 8, minute: 0);
  final _note = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _venue = widget.initialVenue;
    final now = TimeOfDay.now();
    if (now.hour < 22) {
      _start = TimeOfDay(hour: now.hour + 1, minute: 0);
      _end = TimeOfDay(hour: now.hour + 2 > 23 ? 23 : now.hour + 2, minute: 0);
    } else {
      _date = DateTime.now().add(const Duration(days: 1));
    }
  }

  String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

  Future<void> _save() async {
    if (_venue == null) return showSnack(context, 'Pick a venue first', error: true);
    if (_minutes(_end) <= _minutes(_start)) return showSnack(context, 'End time must be after start time', error: true);
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
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, errorMessage(e), error: true);
        setState(() => _saving = false);
      }
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Plan a session')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Where and when are you training? We\'ll find members going at the same time.',
              style: TextStyle(color: FkColors.textSecondary)),
          const SizedBox(height: 20),
          _field(
            icon: Icons.storefront,
            label: 'Venue',
            value: _venue?.name ?? 'Select venue',
            onTap: () async {
              final v = await pickVenue(context);
              if (v != null) setState(() => _venue = v);
            },
          ),
          _field(
            icon: Icons.event,
            label: 'Date',
            value: formatDayDate(_date),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 14)),
              );
              if (d != null) setState(() => _date = d);
            },
          ),
          Row(children: [
            Expanded(
              child: _field(
                icon: Icons.schedule,
                label: 'From',
                value: _start.format(context),
                onTap: () async {
                  final t = await showTimePicker(context: context, initialTime: _start);
                  if (t != null) setState(() => _start = t);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _field(
                icon: Icons.schedule,
                label: 'To',
                value: _end.format(context),
                onTap: () async {
                  final t = await showTimePicker(context: context, initialTime: _end);
                  if (t != null) setState(() => _end = t);
                },
              ),
            ),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            maxLength: 280,
            maxLines: 2,
            decoration: const InputDecoration(hintText: 'Note (optional) — e.g. "Leg day, need a spotter"'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Finding buddies…' : 'Find buddies'),
          ),
        ],
      ),
    );
  }

  Widget _field({required IconData icon, required String label, required String value, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: ListTile(
          onTap: onTap,
          leading: Icon(icon, color: FkColors.lime),
          title: Text(label, style: const TextStyle(fontSize: 12, color: FkColors.textSecondary)),
          subtitle: Text(value,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: FkColors.textPrimary)),
        ),
      ),
    );
  }
}

class BuddyMatchesScreen extends StatefulWidget {
  const BuddyMatchesScreen({super.key, required this.post});

  final BuddyPost post;

  @override
  State<BuddyMatchesScreen> createState() => _BuddyMatchesScreenState();
}

class _BuddyMatchesScreenState extends State<BuddyMatchesScreen> {
  late Future<List<BuddyMatch>> _future = _load();

  Future<List<BuddyMatch>> _load() => context.read<Session>().api.buddyMatches(widget.post.id);

  void _reload() => setState(() => _future = _load());

  Future<void> _request(BuddyMatch m) async {
    try {
      await context.read<Session>().api.sendBuddyRequest(widget.post.id, m.postId);
      if (mounted) showSnack(context, 'Request sent to ${m.name ?? 'member'}');
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  Future<void> _deletePost() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this session?'),
        content: const Text('Your slot will be removed and pending requests cancelled.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Cancel session')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<Session>().api.deleteBuddyPost(widget.post.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Buddies for this slot'),
        actions: [IconButton(tooltip: 'Cancel session', icon: const Icon(Icons.delete_outline), onPressed: _deletePost)],
      ),
      body: Column(children: [
        Container(
          margin: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: FkColors.surface, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            const Icon(Icons.storefront, color: FkColors.lime),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.venueName, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('${formatDayDate(p.slotDate)} · ${formatTimeOfDay(p.slotStart)} – ${formatTimeOfDay(p.slotEnd)}',
                    style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
              ]),
            ),
          ]),
        ),
        Expanded(
          child: AsyncView<List<BuddyMatch>>(
            future: _future,
            onRetry: _reload,
            builder: (context, matches) => matches.isEmpty
                ? const EmptyState(
                    icon: Icons.hourglass_empty,
                    title: 'No one yet',
                    message: 'We\'ll keep your slot open. Check back closer to your session time.',
                  )
                : RefreshIndicator(
                    onRefresh: () async {
                      _reload();
                      await _future;
                    },
                    child: ListView.separated(
                      padding: const EdgeInsets.all(20),
                      itemCount: matches.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _matchCard(matches[i]),
                    ),
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _matchCard(BuddyMatch m) {
    final Widget action = switch ((m.requestStatus, m.requestDirection)) {
      (null, _) => FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 14)),
          onPressed: () => _request(m),
          child: const Text('Go together'),
        ),
      ('pending', 'outgoing') => const Text('Requested', style: TextStyle(color: FkColors.textSecondary)),
      ('pending', 'incoming') => const Text('Wants to join you', style: TextStyle(color: FkColors.orange)),
      ('accepted', _) => const Text('✓ Buddies', style: TextStyle(color: FkColors.lime, fontWeight: FontWeight.w700)),
      _ => const Text('Declined', style: TextStyle(color: FkColors.textSecondary)),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Avatar(name: m.name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.name ?? 'FITKEY member', style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${formatTimeOfDay(m.slotStart)} – ${formatTimeOfDay(m.slotEnd)}',
                  style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
              if (m.note != null && m.note!.isNotEmpty)
                Text('"${m.note}"', style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic)),
            ]),
          ),
          action,
        ]),
      ),
    );
  }
}

class BuddyChatScreen extends StatefulWidget {
  const BuddyChatScreen({super.key, required this.request});

  final BuddyRequest request;

  @override
  State<BuddyChatScreen> createState() => _BuddyChatScreenState();
}

class _BuddyChatScreenState extends State<BuddyChatScreen> {
  final _messages = <ChatMessage>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _poll;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
    // Simple polling keeps Phase 1 free of websockets; swap for a socket/FCM later.
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _fetch());
  }

  Future<void> _fetch() async {
    try {
      final after = _messages.isEmpty ? null : _messages.last.rawCreatedAt;
      final fresh = await context.read<Session>().api.messages(widget.request.id, after: after);
      if (!mounted) return;
      final known = _messages.map((m) => m.id).toSet();
      final added = fresh.where((m) => !known.contains(m.id)).toList();
      setState(() {
        _messages.addAll(added);
        _loading = false;
      });
      if (added.isNotEmpty) _scrollToEnd();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    try {
      final msg = await context.read<Session>().api.sendMessage(widget.request.id, text);
      if (!mounted) return;
      setState(() {
        if (!_messages.any((m) => m.id == msg.id)) _messages.add(msg);
      });
      _scrollToEnd();
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  Future<void> _safetyAction(String action) async {
    final api = context.read<Session>().api;
    final userId = widget.request.otherUserId;
    if (action == 'block') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Block ${widget.request.otherName ?? 'this member'}?'),
          content: const Text('You won\'t see each other in buddy matches or chats.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Block')),
          ],
        ),
      );
      if (ok != true) return;
      await api.blockUser(userId);
      if (mounted) Navigator.pop(context);
    } else {
      final reason = await _askReason();
      if (reason == null || reason.length < 3) return;
      await api.reportUser(userId, reason);
      if (mounted) showSnack(context, 'Thanks — our team will review this report.');
    }
  }

  Future<String?> _askReason() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report member'),
        content: TextField(controller: c, maxLines: 3, decoration: const InputDecoration(hintText: 'What happened?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Report')),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          Avatar(name: r.otherName, radius: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.otherName ?? 'FITKEY member', style: const TextStyle(fontSize: 16)),
              Text('${r.venueName} · ${formatShortDate(r.slotDate)}, ${formatTimeOfDay(r.slotStart)}',
                  style: const TextStyle(fontSize: 12, color: FkColors.textSecondary, fontWeight: FontWeight.w400)),
            ]),
          ),
        ]),
        actions: [
          PopupMenuButton<String>(
            onSelected: _safetyAction,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'report', child: Text('Report')),
              PopupMenuItem(value: 'block', child: Text('Block')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _messages.isEmpty
                  ? const EmptyState(
                      icon: Icons.waving_hand_outlined,
                      title: 'Say hi 👋',
                      message: 'Agree on when to meet at the venue entrance.',
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) => _bubble(_messages[i]),
                    ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  textCapitalization: TextCapitalization.sentences,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: 'Message', contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: FkColors.lime, foregroundColor: Colors.black),
                onPressed: _send,
                icon: const Icon(Icons.send),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _bubble(ChatMessage m) {
    return Align(
      alignment: m.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: m.isMine ? FkColors.lime : FkColors.surfaceHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(m.isMine ? 18 : 4),
            bottomRight: Radius.circular(m.isMine ? 4 : 18),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(m.body, style: TextStyle(color: m.isMine ? Colors.black : FkColors.textPrimary, fontSize: 15)),
          const SizedBox(height: 2),
          Text(formatClock(m.createdAt),
              style: TextStyle(fontSize: 10, color: m.isMine ? Colors.black54 : FkColors.textSecondary)),
        ]),
      ),
    );
  }
}
