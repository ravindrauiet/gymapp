import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/circles_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'circle_detail_screen.dart';
import 'circles_common.dart';

/// Circle vs Circle: average attendance rate this month, by city.
class CircleLeaderboardScreen extends StatefulWidget {
  const CircleLeaderboardScreen({super.key, this.city});
  final String? city;

  @override
  State<CircleLeaderboardScreen> createState() => _CircleLeaderboardScreenState();
}

class _CircleLeaderboardScreenState extends State<CircleLeaderboardScreen> {
  late Future<CircleBoard> _future = context.read<Session>().api.circleLeaderboard(city: widget.city);

  void _reload() => setState(() => _future = context.read<Session>().api.circleLeaderboard(city: widget.city));

  @override
  Widget build(BuildContext context) {
    return CirclesShell(child: Builder(builder: (context) {
      final p = circlesOf(context);
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(title: Text(p.t('leaderboard')), actions: const [CirclesA11yToggles(), SizedBox(width: 12)]),
        body: AsyncBody<CircleBoard>(
          future: _future,
          onRetry: _reload,
          builder: (context, b) => RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
              Text('${p.t('leaderboardSub')}${b.city == null ? '' : ' · ${b.city}'}',
                  style: const TextStyle(color: AppColors.text2)),
              if (b.circleOfTheMonth != null) ...[
                const SizedBox(height: 14),
                CircleOfMonthCard(entry: b.circleOfTheMonth!),
              ],
              const SizedBox(height: 14),
              if (b.entries.isEmpty)
                EmptyView(
                  icon: Icons.emoji_events_rounded,
                  title: p.t('noBoard', {'city': b.city ?? ''}),
                  color: AppColors.amber,
                )
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(children: [for (final e in b.entries) CircleBoardRow(entry: e)]),
                ),
            ]),
          ),
        ),
      );
    }));
  }
}

class CircleOfMonthCard extends StatelessWidget {
  const CircleOfMonthCard({super.key, required this.entry});
  final CircleBoardEntry entry;

  @override
  Widget build(BuildContext context) {
    final p = circlesOf(context);
    return PhotoBanner(
      image: circleVisual(entry.activity).image,
      eyebrow: '${p.t('circleOfMonth')} · ${entry.month ?? ''}',
      title: entry.name,
      subtitle: p.t('rateLabel', {'rate': (entry.rate * 100).round()}),
      cta: p.t('seeAll'),
      height: 150,
      onTap: () => push(context, CircleDetailScreen(circleId: entry.circleId)),
    );
  }
}

class CircleBoardRow extends StatelessWidget {
  const CircleBoardRow({super.key, required this.entry});
  final CircleBoardEntry entry;

  @override
  Widget build(BuildContext context) {
    final p = circlesOf(context);
    final e = entry;
    final medal = switch (e.rank) { 1 => AppColors.amber, 2 => AppColors.text3, 3 => AppColors.primaryDeep, _ => null };
    return ListTile(
      onTap: () => push(context, CircleDetailScreen(circleId: e.circleId)),
      leading: SizedBox(
        width: 40,
        child: Center(
          child: medal != null
              ? Icon(Icons.emoji_events_rounded, color: medal, size: 28)
              : Text('#${e.rank}', style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.text2)),
        ),
      ),
      title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text([if (e.area != null && e.area!.isNotEmpty) e.area!, p.t('members', {'n': e.members})].join(' · ')),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text('${(e.rate * 100).round()}%',
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: AppColors.green)),
        Text(p.t('sessionsN', {'n': e.sessions}), style: const TextStyle(fontSize: 11, color: AppColors.text3)),
      ]),
    );
  }
}
