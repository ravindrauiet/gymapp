import 'package:fitkey_core/fitkey_core.dart' show formatNumber;
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../ui/ui.dart';

/// Top-3 podium followed by the ranked list. The current member's row is highlighted,
/// and pinned to the bottom when they are not in the visible ranking.
///
/// With [shrinkWrap] it renders as a plain column for embedding in another scroll view.
class LeaderboardList extends StatelessWidget {
  const LeaderboardList({super.key, required this.board, required this.myUserId, required this.unit, this.shrinkWrap = false});

  final Leaderboard board;
  final String? myUserId;
  final String unit;
  final bool shrinkWrap;

  static const _medals = [Color(0xFFFFB800), Color(0xFFA9B2BF), Color(0xFFCD7F4A)];

  @override
  Widget build(BuildContext context) {
    final entries = board.entries;
    final me = board.me ?? entries.where((e) => e.userId == myUserId).firstOrNull;
    final meListed = me != null && entries.any((e) => e.userId == me.userId);
    final podium = entries.take(3).toList();
    final rest = entries.skip(podium.length).toList();

    final children = <Widget>[
      if (podium.isNotEmpty) _Podium(entries: podium, myUserId: myUserId, unit: unit, medals: _medals),
      if (rest.isNotEmpty) const SizedBox(height: 14),
      for (final e in rest) ...[
        _LeaderRow(entry: e, isMe: e.userId == myUserId, unit: unit),
        const SizedBox(height: 8),
      ],
    ];

    if (shrinkWrap) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...children,
        if (me != null && !meListed) ...[
          const SizedBox(height: 6),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('YOUR POSITION',
                style: TextStyle(fontSize: 11.5, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: AppColors.text3)),
          ),
          _LeaderRow(entry: me, isMe: true, unit: unit),
        ],
      ]);
    }

    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: children,
    );
    if (me == null || meListed) return list;
    return Column(children: [
      Expanded(child: list),
      Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          boxShadow: [BoxShadow(color: Color(0x141A1B25), blurRadius: 16, offset: Offset(0, -4))],
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: _LeaderRow(entry: me, isMe: true, unit: unit, flat: true),
      ),
    ]);
  }
}

class _Podium extends StatelessWidget {
  const _Podium({required this.entries, required this.myUserId, required this.unit, required this.medals});
  final List<LeaderEntry> entries;
  final String? myUserId;
  final String unit;
  final List<Color> medals;

  @override
  Widget build(BuildContext context) {
    // Display order: 2nd, 1st, 3rd.
    final order = <int>[if (entries.length > 1) 1, 0, if (entries.length > 2) 2];
    const heights = [96.0, 68.0, 50.0];
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
      radius: 22,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final i in order)
            Expanded(
              child: _PodiumSpot(
                entry: entries[i],
                place: i + 1,
                color: medals[i],
                pedestal: heights[i],
                isMe: entries[i].userId == myUserId,
                unit: unit,
              ),
            ),
        ],
      ),
    );
  }
}

class _PodiumSpot extends StatelessWidget {
  const _PodiumSpot({
    required this.entry,
    required this.place,
    required this.color,
    required this.pedestal,
    required this.isMe,
    required this.unit,
  });
  final LeaderEntry entry;
  final int place;
  final Color color;
  final double pedestal;
  final bool isMe;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final first = place == 1;
    final size = first ? 72.0 : 58.0;
    final name = isMe ? 'You' : (entry.name ?? 'Member').split(' ').first;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (first) const Icon(Icons.workspace_premium_rounded, color: Color(0xFFFFB800), size: 26),
        SizedBox(
          width: size + 10,
          height: size + 18,
          child: Stack(alignment: Alignment.topCenter, children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [color, color.withValues(alpha: 0.55)]),
                boxShadow: AppShadows.glow(color),
              ),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(color: AppColors.surface, shape: BoxShape.circle),
                child: PersonAvatar(name: entry.name, size: size - 6),
              ),
            ),
            Positioned(
              bottom: 0,
              child: Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.surface, width: 2),
                ),
                child: Text('$place', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 6),
        Text(name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w800, color: isMe ? AppColors.primary : AppColors.text)),
        Text('${formatNumber(entry.score)} $unit',
            maxLines: 1,
            style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Container(
          height: pedestal,
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [color.withValues(alpha: 0.30), color.withValues(alpha: 0.08)],
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          ),
          alignment: Alignment.topCenter,
          padding: const EdgeInsets.only(top: 8),
          child: Text('#$place',
              style: TextStyle(fontSize: first ? 22 : 18, fontWeight: FontWeight.w800, color: color, letterSpacing: -0.5)),
        ),
      ]),
    );
  }
}

class _LeaderRow extends StatelessWidget {
  const _LeaderRow({required this.entry, required this.isMe, required this.unit, this.flat = false});
  final LeaderEntry entry;
  final bool isMe;
  final String unit;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isMe ? AppColors.primarySoft : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isMe ? AppColors.primary.withValues(alpha: 0.45) : AppColors.line),
        boxShadow: flat || isMe ? null : AppShadows.soft,
      ),
      child: Row(children: [
        SizedBox(
          width: 34,
          child: Text('${e.rank}',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 15, color: isMe ? AppColors.primary : AppColors.text2)),
        ),
        const SizedBox(width: 8),
        PersonAvatar(name: e.name, size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(e.name ?? 'FITKEY member',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
              ),
              if (isMe) ...[const SizedBox(width: 6), const Tag('YOU', solid: true, dense: true)],
            ]),
            if (e.city != null)
              Text(e.city!, style: const TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
          ]),
        ),
        Text.rich(TextSpan(children: [
          TextSpan(text: formatNumber(e.score), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          TextSpan(
              text: ' $unit', style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600)),
        ])),
      ]),
    );
  }
}
