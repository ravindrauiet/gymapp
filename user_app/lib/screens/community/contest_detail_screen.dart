import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import '../health/log_sheets.dart';
import 'community_screen.dart';

class ContestDetailScreen extends StatefulWidget {
  const ContestDetailScreen({super.key, required this.contestId});

  final String contestId;

  @override
  State<ContestDetailScreen> createState() => _ContestDetailScreenState();
}

class _ContestDetailScreenState extends State<ContestDetailScreen> {
  late Future<({Contest contest, Leaderboard leaderboard})> _future = _load();
  bool _joining = false;

  Future<({Contest contest, Leaderboard leaderboard})> _load() =>
      context.read<Session>().api.contest(widget.contestId);

  void _reload() => setState(() => _future = _load());

  Future<void> _join() async {
    setState(() => _joining = true);
    try {
      await context.read<Session>().api.joinContest(widget.contestId);
      if (mounted) showSnack(context, 'You\'re in! Good luck 💪');
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  String _howTo(String metric) => switch (metric) {
        'running_km' => 'Log your runs from the Progress screen. Total kilometres between the start and end dates count.',
        'streak' => 'Check in at any FITKEY venue on consecutive days. Your longest streak in the contest window counts.',
        _ => 'Check in at any FITKEY venue. Each day you check in counts once.',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Contest')),
      body: AsyncView<({Contest contest, Leaderboard leaderboard})>(
        future: _future,
        onRetry: _reload,
        builder: (context, data) {
          final c = data.contest;
          final finished = c.endsOn.isBefore(DateTime.now().subtract(const Duration(days: 1)));
          return ListView(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 32),
            children: [
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                      colors: [Color(0xFF3B2414), Color(0xFF1B1F25)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  border: Border.all(color: FkColors.orange.withValues(alpha: 0.4)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${c.period.toUpperCase()} CHALLENGE',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: FkColors.orange)),
                  const SizedBox(height: 8),
                  Text(c.title, style: Theme.of(context).textTheme.headlineSmall),
                  if (c.description != null) ...[
                    const SizedBox(height: 6),
                    Text(c.description!, style: const TextStyle(color: FkColors.textSecondary)),
                  ],
                  const SizedBox(height: 16),
                  Wrap(spacing: 16, runSpacing: 8, children: [
                    _meta(Icons.event, '${formatShortDate(c.startsOn)} – ${formatShortDate(c.endsOn)}'),
                    _meta(Icons.people_outline, '${c.participantCount} players'),
                    if (c.city != null) _meta(Icons.location_on_outlined, c.city!),
                  ]),
                  if (c.reward != null) ...[
                    const SizedBox(height: 16),
                    Row(children: [
                      const Icon(Icons.card_giftcard, color: Color(0xFFFFC145)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(c.reward!,
                            style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFFFC145))),
                      ),
                    ]),
                  ],
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Text(_howTo(c.metric), style: const TextStyle(color: FkColors.textSecondary, height: 1.4)),
              ),
              if (!finished)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: c.joined
                      ? (c.metric == 'running_km'
                          ? OutlinedButton.icon(
                              icon: const Icon(Icons.directions_run),
                              label: const Text('Log a run'),
                              onPressed: () async {
                                final logged = await showActivitySheet(context, initialType: 'running');
                                if (logged) _reload();
                              },
                            )
                          : const SizedBox.shrink())
                      : FilledButton(
                          onPressed: _joining ? null : _join,
                          child: Text(_joining ? 'Joining…' : 'Join contest'),
                        ),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: SectionHeader('Leaderboard'),
              ),
              if (data.leaderboard.entries.isEmpty)
                const EmptyState(icon: Icons.leaderboard_outlined, title: 'Be the first to join!')
              else
                LeaderboardList(
                  board: data.leaderboard,
                  myUserId: context.read<Session>().user?.id,
                  unit: c.unit,
                  shrinkWrap: true,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _meta(IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: FkColors.textSecondary),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 13, color: FkColors.textSecondary)),
      ]);
}
