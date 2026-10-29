import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/events_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'contest_detail_screen.dart';
import 'event_widgets.dart';
import 'org_verify_sheet.dart';

/// Suggested searches shown when nothing matches (Community search empty state).
const communitySearchSuggestions = ['Running', 'Push-ups', 'Streak', 'Squats', 'Yoga', 'Check-in', 'Plank'];

/// Events tab inside Community (BRD §3.1): All / My Org / Open × Live / Upcoming / Past.
class EventsTab extends StatefulWidget {
  const EventsTab({super.key, this.query = '', this.onSuggestion});

  /// Community search text — filters events by name, org, venue or area.
  final String query;

  /// Called when the member taps a suggested category in the "No results" state.
  final ValueChanged<String>? onSuggestion;

  @override
  State<EventsTab> createState() => _EventsTabState();
}

class _EventsTabState extends State<EventsTab> with AutomaticKeepAliveClientMixin {
  String _scope = 'all';
  String _status = 'live';
  late Future<EventsPage> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(EventsTab old) {
    super.didUpdateWidget(old);
    if (old.query.trim() != widget.query.trim()) _reload();
  }

  Future<EventsPage> _load() {
    final q = widget.query.trim();
    return context.read<Session>().api.events(scope: _scope, status: _status, query: q.isEmpty ? null : q);
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* shown by the FutureBuilder */}
  }

  Future<void> _open(FitEvent e) async {
    await push(context, ContestDetailScreen(contestId: e.id));
    if (mounted) _reload();
  }

  Future<void> _verify() async {
    final m = await showOrgVerifySheet(context, orgs: const []);
    if (m != null && mounted) {
      toast(context, m.verified ? 'Verified at ${m.orgName}' : 'Sent for review');
      _scope = 'org';
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final searching = widget.query.trim().isNotEmpty;
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 32),
        children: [
          if (!searching) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: PhotoBanner(
                image: AppImages.running,
                eyebrow: 'FitKey events',
                title: 'Compete with your city, office & campus.',
                subtitle: 'Virtual, on-ground and AI-verified events — every one has its own leaderboard.',
                height: 150,
              ),
            ),
            const SizedBox(height: 18),
          ],
          ChoiceChips<String>(
            options: const ['all', 'org', 'open'],
            selected: _scope,
            label: (s) => switch (s) { 'org' => 'My Org', 'open' => 'Open', _ => 'All' },
            icon: (s) => switch (s) {
              'org' => Icons.business_rounded,
              'open' => Icons.public_rounded,
              _ => Icons.apps_rounded,
            },
            onSelected: (s) {
              if (s == _scope) return;
              _scope = s;
              _reload();
            },
          ),
          const SizedBox(height: 8),
          ChoiceChips<String>(
            options: const ['live', 'upcoming', 'past'],
            selected: _status,
            label: (s) => switch (s) { 'live' => 'Live', 'upcoming' => 'Upcoming', _ => 'Past' },
            icon: (s) => switch (s) {
              'live' => Icons.bolt_rounded,
              'upcoming' => Icons.event_rounded,
              _ => Icons.history_rounded,
            },
            onSelected: (s) {
              if (s == _status) return;
              _status = s;
              _reload();
            },
          ),
          const SizedBox(height: 16),
          FutureBuilder<EventsPage>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const EventCardsSkeleton();
              if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
              final page = snap.data!;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (!searching) _OrgStrip(memberships: page.myOrgs, onVerify: _verify),
                if (page.events.isEmpty)
                  searching ? _noResults() : _empty(page)
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(children: [
                      for (final e in page.events) ...[
                        EventCard(event: e, onTap: () => _open(e)),
                        const SizedBox(height: 14),
                      ],
                    ]),
                  ),
              ]);
            },
          ),
        ],
      ),
    );
  }

  Widget _noResults() => EmptyView(
        icon: Icons.search_off_rounded,
        color: AppColors.text2,
        title: 'No results',
        message: 'No events match “${widget.query.trim()}”. Try one of these:',
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final s in communitySearchSuggestions)
              ActionChip(
                label: Text(s),
                avatar: const Icon(Icons.north_west_rounded, size: 14),
                onPressed: () => widget.onSuggestion?.call(s),
              ),
          ],
        ),
      );

  Widget _empty(EventsPage page) {
    if (_scope == 'org' && !page.myOrgs.any((m) => m.verified)) {
      return EmptyView(
        icon: Icons.business_rounded,
        color: AppColors.purple,
        title: 'Verify your organisation',
        message: 'Company and college events appear here once you verify with your official email or invite code.',
        action: SizedBox(
          width: 200,
          child: FilledButton.icon(onPressed: _verify, icon: const Icon(Icons.verified_user_rounded), label: const Text('Verify now')),
        ),
      );
    }
    return EmptyView(
      icon: Icons.emoji_events_rounded,
      color: AppColors.amber,
      title: switch (_status) {
        'live' => 'No live events right now',
        'upcoming' => 'Nothing scheduled yet',
        _ => 'No past events',
      },
      message: _status == 'past'
          ? 'Finished events and their winners will show up here.'
          : 'New events drop regularly. Keep training so you are ready to climb.',
      action: _status == 'live'
          ? SizedBox(
              width: 200,
              child: OutlinedButton(
                onPressed: () {
                  _status = 'upcoming';
                  _reload();
                },
                child: const Text('See upcoming'),
              ),
            )
          : null,
    );
  }
}

class _OrgStrip extends StatelessWidget {
  const _OrgStrip({required this.memberships, required this.onVerify});
  final List<OrgMembership> memberships;
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    if (memberships.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: AppCard(
          onTap: onVerify,
          color: AppColors.purpleSoft,
          shadow: false,
          padding: const EdgeInsets.all(14),
          child: const Row(children: [
            IconBubble(Icons.business_center_rounded, color: AppColors.purple, bg: Colors.white, size: 42),
            SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Office or college events?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                SizedBox(height: 2),
                Text('Verify with your work / college email to unlock them',
                    style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.purple),
          ]),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final m in memberships) OrgBadgeChip(name: m.orgName, college: m.isCollege, pending: !m.verified),
        Tap(
          onTap: onVerify,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.line),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add_rounded, size: 15, color: AppColors.text2),
              SizedBox(width: 4),
              Text('Add org', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: AppColors.text2)),
            ]),
          ),
        ),
      ]),
    );
  }
}
