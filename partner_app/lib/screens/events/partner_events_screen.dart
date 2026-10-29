import 'package:fitkey_core/fitkey_core.dart' show formatDayDate, formatShortDate, formatNumber;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams;

import '../../data/insights_api.dart';
import '../../data/models.dart' show VenueStatus;
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../checkin/checkin_code_screen.dart';
import '../notifications/notifications_screen.dart';
import 'event_form_screen.dart';

/// BRD §3.1 Partner Events — challenges, bootcamps and AI-verified contests hosted at the partner's venues.
class PartnerEventsScreen extends StatefulWidget {
  const PartnerEventsScreen({super.key, this.venueId});

  /// Pre-selects / filters to one venue when opened from that venue.
  final String? venueId;

  @override
  State<PartnerEventsScreen> createState() => _PartnerEventsScreenState();
}

const _statuses = ['live', 'upcoming', 'past'];
String _statusLabel(String s) => switch (s) {
      'live' => 'Live',
      'upcoming' => 'Upcoming',
      _ => 'Past',
    };

class _PartnerEventsScreenState extends State<PartnerEventsScreen> {
  PartnerEventList? _data;
  Object? _error;
  bool _loading = true;
  String? _status;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final d = await context.read<PartnerSession>().api.partnerEvents(venueId: widget.venueId);
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
        _status ??= d.live > 0 ? 'live' : (d.upcoming > 0 ? 'upcoming' : (d.past > 0 ? 'past' : 'live'));
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  Future<void> _create() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final venues = await context.read<PartnerSession>().api.venues();
      if (!mounted) return;
      final live = venues.where((v) => v.status == VenueStatus.live).toList();
      if (live.isEmpty) {
        toast(context, 'Your venue needs to be live on FitKey before it can host events', error: true);
        return;
      }
      final created = await push<PartnerEvent>(
        context,
        PartnerEventFormScreen(venues: live, initialVenueId: widget.venueId),
      );
      if (!mounted || created == null) return;
      setState(() => _status = created.status);
      await _load();
      if (mounted) await push(context, PartnerEventDetailScreen(eventId: created.id));
      if (mounted) _load();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _open(PartnerEvent e) async {
    await push(context, PartnerEventDetailScreen(eventId: e.id));
    if (mounted) _load();
  }

  int _count(String s) => switch (s) {
        'live' => _data?.live ?? 0,
        'upcoming' => _data?.upcoming ?? 0,
        _ => _data?.past ?? 0,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Events'),
        actions: const [PartnerNotificationBell(), SizedBox(width: 8)],
      ),
      floatingActionButton: _data == null
          ? null
          : FloatingActionButton.extended(
              heroTag: 'partner-events-create',
              onPressed: _opening ? null : _create,
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              icon: _opening
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                  : const Icon(Icons.add_rounded),
              label: const Text('Create event', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const SkeletonList(itemHeight: 110);
    if (_error != null && _data == null) return ErrorView(error: _error!, onRetry: _load);
    final d = _data!;
    final status = _status ?? 'live';
    final events = d.events.where((e) => e.status == status).toList();
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 14, bottom: 100),
        children: [
          if (d.events.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: PhotoBanner(
                image: AppImages.groupClass,
                eyebrow: 'Partner events',
                title: 'Fill your floor with a challenge',
                subtitle: 'Bootcamps, 30-day check-in challenges and AI rep battles — members join from the FitKey app.',
                cta: 'Create your first event',
                onTap: _create,
              ),
            ),
          if (d.events.isNotEmpty)
            ChoiceChips<String>(
              options: _statuses,
              selected: status,
              onSelected: (s) => setState(() => _status = s),
              label: (s) => _count(s) > 0 ? '${_statusLabel(s)} · ${_count(s)}' : _statusLabel(s),
              icon: (s) => switch (s) {
                'live' => Icons.bolt_rounded,
                'upcoming' => Icons.schedule_rounded,
                _ => Icons.history_rounded,
              },
            ),
          const SizedBox(height: 6),
          if (events.isEmpty)
            EmptyView(
              icon: Icons.event_available_rounded,
              color: AppColors.purple,
              title: d.events.isEmpty ? 'No events yet' : 'No ${_statusLabel(status).toLowerCase()} events',
              message: status == 'past'
                  ? 'Finished events and their leaderboards appear here.'
                  : 'Host a challenge or an on-ground bootcamp — registered members get reminders and you see who turns up.',
              action: status == 'past'
                  ? null
                  : SizedBox(
                      width: 200,
                      child: OutlinedButton.icon(
                          onPressed: _create, icon: const Icon(Icons.add_rounded), label: const Text('Create event')),
                    ),
            )
          else
            for (final e in events)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: PartnerEventCard(event: e, onTap: () => _open(e)),
              ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

String eventCoverFallback(PartnerEvent e) {
  if (e.format == EventFormat.ai) return AppImages.battleRopes;
  if (e.metric == 'running_km') return AppImages.running;
  return venueVisual(e.venue.categories.isEmpty ? 'gym' : e.venue.categories.first).image;
}

String eventWhen(PartnerEvent e) {
  if (e.format == EventFormat.onground && e.eventDate != null) return formatDayDate(e.eventDate!);
  if (e.startsOn == e.endsOn) return formatDayDate(e.startsOn);
  return '${formatShortDate(e.startsOn)} – ${formatShortDate(e.endsOn)}';
}

(Color, IconData) _statusLook(String s) => switch (s) {
      'live' => (AppColors.green, Icons.bolt_rounded),
      'upcoming' => (AppColors.blue, Icons.schedule_rounded),
      _ => (AppColors.text2, Icons.history_rounded),
    };

IconData _formatIcon(EventFormat f) => switch (f) {
      EventFormat.virtual => Icons.public_rounded,
      EventFormat.onground => Icons.place_rounded,
      EventFormat.ai => Icons.auto_awesome_rounded,
    };

class PartnerEventCard extends StatelessWidget {
  const PartnerEventCard({super.key, required this.event, this.onTap});
  final PartnerEvent event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final (sc, si) = _statusLook(e.status);
    return AppCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SizedBox(
            height: 150,
            child: Stack(fit: StackFit.expand, children: [
              NetImage(e.coverUrl ?? e.venue.photo, fallback: eventCoverFallback(e)),
              const PhotoScrim(strength: 0.82),
              Positioned(
                top: 12,
                left: 12,
                child: Tag(_statusLabel(e.status).toUpperCase(), color: sc, icon: si, solid: true),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: Tag(e.format.label, color: AppColors.ink, bg: Colors.white, icon: _formatIcon(e.format)),
              ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 12,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18, height: 1.2, letterSpacing: -0.3)),
                  const SizedBox(height: 3),
                  Text('${eventWhen(e)} · ${e.metricLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.88), fontSize: 12.5, fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Row(children: [
            const Icon(Icons.storefront_rounded, size: 16, color: AppColors.text3),
            const SizedBox(width: 6),
            Expanded(
              child: Text(e.venue.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.text2)),
            ),
            if (e.membersOnly) ...[
              const Tag('Members only', color: AppColors.purple, icon: Icons.lock_rounded, dense: true),
              const SizedBox(width: 6),
            ],
            if (!e.canEdit) ...[
              const Tag('By FitKey', color: AppColors.primary, dense: true),
              const SizedBox(width: 6),
            ],
            const Icon(Icons.groups_rounded, size: 17, color: AppColors.primary),
            const SizedBox(width: 4),
            Text(
              e.format == EventFormat.onground && e.attendedCount > 0
                  ? '${formatNumber(e.attendedCount)}/${formatNumber(e.participantCount)}'
                  : formatNumber(e.participantCount),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------

class PartnerEventDetailScreen extends StatefulWidget {
  const PartnerEventDetailScreen({super.key, required this.eventId});
  final String eventId;

  @override
  State<PartnerEventDetailScreen> createState() => _PartnerEventDetailScreenState();
}

class _PartnerEventDetailScreenState extends State<PartnerEventDetailScreen> {
  PartnerEventDetail? _d;
  Object? _error;
  bool _loading = true;
  bool _busy = false;
  String _tab = 'participants';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _d == null;
      _error = null;
    });
    try {
      final d = await context.read<PartnerSession>().api.partnerEvent(widget.eventId);
      if (!mounted) return;
      setState(() {
        _d = d;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  Future<void> _share(PartnerEvent e) async {
    final where = e.venue.location.isEmpty ? e.venue.name : '${e.venue.name}, ${e.venue.location}';
    final lines = [
      '${e.title} — at $where',
      '${eventWhen(e)} · ${e.format.label} · ${e.metricLabel}',
      if (e.reward != null) 'Win: ${e.reward}',
      if (e.membersOnly) 'Open to ${e.venue.name} members.',
      'Join free in the FITKEY app → Events.',
    ];
    try {
      await SharePlus.instance.share(ShareParams(text: lines.join('\n'), subject: e.title));
    } catch (_) {
      if (mounted) toast(context, 'Couldn\'t open the share sheet', error: true);
    }
  }

  Future<void> _edit(PartnerEvent e) async {
    setState(() => _busy = true);
    try {
      final venues = await context.read<PartnerSession>().api.venues();
      if (!mounted) return;
      final live = venues.where((v) => v.status == VenueStatus.live).toList();
      final r = await push<PartnerEvent>(context, PartnerEventFormScreen(venues: live, event: e));
      if (r != null && mounted) await _load();
    } catch (err) {
      if (mounted) toast(context, friendlyError(err), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(PartnerEvent e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this event?'),
        content: Text(e.participantCount == 0
            ? 'It will be removed from the FitKey app.'
            : 'It will be removed from the FitKey app and ${e.participantCount} registered '
                'member${e.participantCount == 1 ? '' : 's'} will be notified.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('Cancel event'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final n = await context.read<PartnerSession>().api.deletePartnerEvent(e.id);
      if (!mounted) return;
      toast(context, n == 0 ? 'Event cancelled' : 'Event cancelled · $n member${n == 1 ? '' : 's'} notified');
      Navigator.of(context).pop(true);
    } catch (err) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, friendlyError(err), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = _d?.event;
    final editable = e != null && e.canEdit && !e.isPast;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Event'),
        actions: [
          if (editable)
            IconButton(
              tooltip: 'Edit',
              onPressed: _busy ? null : () => _edit(e),
              icon: const Icon(Icons.edit_rounded),
            ),
          if (editable)
            PopupMenuButton<String>(
              enabled: !_busy,
              onSelected: (v) {
                if (v == 'cancel') _cancel(e);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'cancel',
                  child: Row(children: [
                    Icon(Icons.event_busy_rounded, color: AppColors.red, size: 20),
                    SizedBox(width: 10),
                    Text('Cancel event'),
                  ]),
                ),
              ],
            ),
        ],
      ),
      bottomNavigationBar: e == null
          ? null
          : BottomActionBar(
              child: AppButton(
                label: 'Share with members',
                icon: Icons.ios_share_rounded,
                onPressed: () => _share(e),
              ),
            ),
      body: _loading
          ? const _DetailSkeleton()
          : _error != null && _d == null
              ? ErrorView(error: _error!, onRetry: _load)
              : RefreshIndicator(color: AppColors.primary, onRefresh: _load, child: _content(_d!)),
    );
  }

  Widget _content(PartnerEventDetail d) {
    final e = d.event;
    final (sc, si) = _statusLook(e.status);
    final top = d.leaderboard.isEmpty ? null : d.leaderboard.first;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: SizedBox(
            height: 200,
            child: Stack(fit: StackFit.expand, children: [
              NetImage(e.coverUrl ?? e.venue.photo, fallback: eventCoverFallback(e)),
              const PhotoScrim(strength: 0.85),
              Positioned(top: 12, left: 12, child: Tag(_statusLabel(e.status).toUpperCase(), color: sc, icon: si, solid: true)),
              Positioned(
                left: 16,
                right: 16,
                bottom: 14,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    Tag(e.format.label, color: AppColors.ink, bg: Colors.white, icon: _formatIcon(e.format), dense: true),
                    if (e.membersOnly)
                      const Tag('Members only', color: AppColors.ink, bg: Colors.white, icon: Icons.lock_rounded, dense: true),
                    if (!e.canEdit) const Tag('Run by FitKey', color: AppColors.ink, bg: Colors.white, dense: true),
                  ]),
                  const SizedBox(height: 8),
                  Text(e.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22, height: 1.15, letterSpacing: -0.4)),
                ]),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: MetricTile(
                label: 'Registered', value: formatNumber(e.participantCount), icon: Icons.groups_rounded, color: AppColors.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: e.format == EventFormat.onground
                ? MetricTile(
                    label: 'Attended', value: formatNumber(e.attendedCount), icon: Icons.how_to_reg_rounded, color: AppColors.green)
                : MetricTile(
                    label: 'Top score',
                    value: top == null ? '–' : _score(top.score),
                    unit: top == null ? null : e.unit,
                    icon: Icons.emoji_events_rounded,
                    color: AppColors.amber),
          ),
        ]),
        const SizedBox(height: 14),
        AppCard(
          child: Column(children: [
            _InfoRow(Icons.calendar_month_rounded, e.format == EventFormat.onground ? 'Event day' : 'Runs', eventWhen(e)),
            _InfoRow(Icons.storefront_rounded, 'Venue', e.venue.location.isEmpty ? e.venue.name : '${e.venue.name} · ${e.venue.location}'),
            _InfoRow(Icons.leaderboard_rounded, 'Ranked by', e.metricLabel),
            _InfoRow(Icons.lock_open_rounded, 'Who can join', e.membersOnly ? 'Your venue members only' : 'Anyone on FitKey'),
            if (e.city != null) _InfoRow(Icons.location_city_rounded, 'City', e.city!),
            if (e.reward != null) _InfoRow(Icons.card_giftcard_rounded, 'Reward', e.reward!),
            if (e.sponsor != null) _InfoRow(Icons.handshake_rounded, 'Sponsor', e.sponsor!, last: true),
          ]),
        ),
        if (e.format == EventFormat.onground && !e.isPast) ...[
          const SizedBox(height: 14),
          AppCard(
            color: AppColors.greenSoft,
            shadow: false,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                IconBubble(Icons.qr_code_2_rounded, color: AppColors.green, bg: AppColors.surface),
                SizedBox(width: 12),
                Expanded(
                  child: Text('Attendance is automatic',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                'On ${eventWhen(e)}, registered members scan your front-desk check-in QR at ${e.venue.name} '
                '— they\'re marked attended instantly, even without a plan.',
                style: const TextStyle(color: AppColors.text2, height: 1.4),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => push(context, CheckinCodeScreen(venueId: e.venue.id, venueName: e.venue.name)),
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('Open front-desk QR'),
                ),
              ),
            ]),
          ),
        ],
        if (e.description != null) ...[
          const SectionTitle('About', padding: EdgeInsets.fromLTRB(0, 22, 0, 10)),
          AppCard(child: Text(e.description!, style: const TextStyle(color: AppColors.text2, height: 1.5))),
        ],
        const SizedBox(height: 22),
        ChoiceChips<String>(
          padding: EdgeInsets.zero,
          options: const ['participants', 'leaderboard'],
          selected: _tab,
          onSelected: (t) => setState(() => _tab = t),
          label: (t) => t == 'participants' ? 'Participants · ${d.participants.length}' : 'Leaderboard',
          icon: (t) => t == 'participants' ? Icons.groups_rounded : Icons.emoji_events_rounded,
        ),
        const SizedBox(height: 12),
        if (_tab == 'participants') ..._participants(d) else ..._leaderboard(d),
      ],
    );
  }

  String _score(double v) => v == v.roundToDouble() ? formatNumber(v.round()) : v.toStringAsFixed(1);

  List<Widget> _participants(PartnerEventDetail d) {
    final e = d.event;
    if (d.participants.isEmpty) {
      return [
        EmptyView(
          icon: Icons.group_add_rounded,
          color: AppColors.purple,
          title: 'No registrations yet',
          message: 'Share the event with your members — they join in seconds from the FitKey app.',
          action: SizedBox(
            width: 180,
            child: OutlinedButton.icon(
                onPressed: () => _share(e), icon: const Icon(Icons.ios_share_rounded), label: const Text('Share')),
          ),
        ),
      ];
    }
    final onground = e.format == EventFormat.onground;
    return [
      AppCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(children: [
          for (var i = 0; i < d.participants.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 66),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                PersonAvatar(name: d.participants[i].name, photoUrl: d.participants[i].avatarUrl, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(d.participants[i].name,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      [
                        if (d.participants[i].city != null) d.participants[i].city!,
                        if (d.participants[i].joinedAt != null) 'joined ${formatShortDate(d.participants[i].joinedAt!)}',
                      ].join(' · '),
                      style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ]),
                ),
                if (onground)
                  d.participants[i].attended
                      ? const Tag('Attended', color: AppColors.green, icon: Icons.check_circle_rounded, dense: true)
                      : Tag(e.isPast ? 'No-show' : 'Registered', color: e.isPast ? AppColors.red : AppColors.text2, dense: true),
              ]),
            ),
          ],
        ]),
      ),
    ];
  }

  List<Widget> _leaderboard(PartnerEventDetail d) {
    final e = d.event;
    if (d.leaderboard.isEmpty) {
      return const [
        EmptyView(
          icon: Icons.emoji_events_outlined,
          color: AppColors.amber,
          title: 'Leaderboard is empty',
          message: 'Scores appear as registered members train — the same live board they see in the app.',
        ),
      ];
    }
    return [
      AppCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(children: [
          for (var i = 0; i < d.leaderboard.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 66),
            _LeaderRow(entry: d.leaderboard[i], unit: e.unit, score: _score(d.leaderboard[i].score)),
          ],
        ]),
      ),
    ];
  }
}

class _LeaderRow extends StatelessWidget {
  const _LeaderRow({required this.entry, required this.unit, required this.score});
  final EventLeaderboardEntry entry;
  final String unit;
  final String score;

  @override
  Widget build(BuildContext context) {
    final medal = switch (entry.rank) {
      1 => const Color(0xFFFFB800),
      2 => const Color(0xFFA7B0BE),
      3 => const Color(0xFFCD7F32),
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: [
        SizedBox(
          width: 28,
          child: medal == null
              ? Text('${entry.rank}',
                  textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.text2))
              : Icon(Icons.emoji_events_rounded, color: medal, size: 22),
        ),
        const SizedBox(width: 8),
        PersonAvatar(name: entry.name, photoUrl: entry.avatarUrl, size: 36),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (entry.city != null)
              Text(entry.city!, style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
        Text.rich(TextSpan(children: [
          TextSpan(text: score, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          if (unit.isNotEmpty)
            TextSpan(text: ' $unit', style: const TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600)),
        ])),
      ]),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.icon, this.label, this.value, {this.last = false});
  final IconData icon;
  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconBubble(icon, color: AppColors.text2, size: 32, bg: AppColors.surfaceAlt),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 1),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, height: 1.3)),
          ]),
        ),
      ]),
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: SingleChildScrollView(
        physics: NeverScrollableScrollPhysics(),
        padding: EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SkeletonBox(height: 200, radius: 22),
          SizedBox(height: 14),
          Row(children: [
            Expanded(child: SkeletonBox(height: 96, radius: 20)),
            SizedBox(width: 10),
            Expanded(child: SkeletonBox(height: 96, radius: 20)),
          ]),
          SizedBox(height: 14),
          SkeletonBox(height: 180, radius: 20),
          SizedBox(height: 22),
          SkeletonBox(height: 40, width: 260, radius: 12),
          SizedBox(height: 12),
          SkeletonBox(height: 160, radius: 20),
        ]),
      ),
    );
  }
}
