import 'package:fitkey_core/fitkey_core.dart' show formatShortDate;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../../data/insights_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../checkin/checkin_code_screen.dart';
import '../trainer/partner_trainer_screen.dart';

/// BRD §8 — what members think of the partner's venues and trainer profile:
/// average, star histogram, sub-ratings, monthly trend, anonymous recent ratings and tips to improve.
class PartnerRatingsScreen extends StatefulWidget {
  const PartnerRatingsScreen({super.key, this.venueId, this.trainer = false});

  /// Opens on this venue's ratings.
  final String? venueId;

  /// Opens on the trainer profile's ratings.
  final bool trainer;

  @override
  State<PartnerRatingsScreen> createState() => _PartnerRatingsScreenState();
}

class _PartnerRatingsScreenState extends State<PartnerRatingsScreen> {
  RatingTargets? _targets;
  Object? _error;
  bool _loading = true;

  RatingTarget? _selected;
  RatingsSummary? _summary;
  final List<RatingEntry> _feed = [];
  String? _next;
  bool _loadingTarget = false;
  bool _loadingMore = false;
  Object? _targetError;

  @override
  void initState() {
    super.initState();
    _loadTargets();
  }

  Future<void> _loadTargets() async {
    setState(() {
      _loading = _targets == null;
      _error = null;
    });
    try {
      final t = await context.read<PartnerSession>().api.ratingTargets();
      if (!mounted) return;
      RatingTarget? pick;
      final keep = _selected;
      if (keep != null) pick = t.all.where((x) => x.id == keep.id && x.isTrainer == keep.isTrainer).firstOrNull;
      if (pick == null && widget.trainer) pick = t.trainer;
      if (pick == null && widget.venueId != null) pick = t.venues.where((v) => v.id == widget.venueId).firstOrNull;
      pick ??= t.venues.firstOrNull ?? t.trainer;
      setState(() {
        _targets = t;
        _selected = pick;
        _loading = false;
      });
      if (pick != null) await _loadTarget();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  Future<void> _loadTarget() async {
    final target = _selected;
    if (target == null) return;
    final api = context.read<PartnerSession>().api;
    final venueId = target.isTrainer ? null : target.id;
    setState(() {
      _loadingTarget = _summary == null;
      _targetError = null;
    });
    try {
      final results = await Future.wait<Object>([api.ratingsSummary(venueId: venueId), api.ratingsFeed(venueId: venueId)]);
      final summary = results[0] as RatingsSummary;
      final page = results[1] as RatingsPage;
      if (!mounted || _selected != target) return;
      setState(() {
        _summary = summary;
        _feed
          ..clear()
          ..addAll(page.ratings);
        _next = page.nextBefore;
        _loadingTarget = false;
      });
    } catch (e) {
      if (mounted && _selected == target) {
        setState(() {
          _loadingTarget = false;
          _targetError = e;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    final target = _selected;
    if (target == null || _next == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await context
          .read<PartnerSession>()
          .api
          .ratingsFeed(venueId: target.isTrainer ? null : target.id, before: _next);
      if (!mounted || _selected != target) return;
      setState(() {
        _feed.addAll(page.ratings);
        _next = page.nextBefore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      toast(context, friendlyError(e), error: true);
    }
  }

  void _select(RatingTarget t) {
    if (t == _selected) return;
    setState(() {
      _selected = t;
      _summary = null;
      _feed.clear();
      _next = null;
    });
    _loadTarget();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Ratings')),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const _RatingsSkeleton();
    if (_error != null) return ErrorView(error: _error!, onRetry: _loadTargets);
    final targets = _targets!;
    if (targets.all.isEmpty) {
      return EmptyView(
        icon: Icons.star_outline_rounded,
        color: AppColors.amber,
        title: 'Nothing to rate yet',
        message: 'Once your venue is live — or you set up a trainer profile — members can rate you after each visit or session.',
        action: SizedBox(
          width: 230,
          child: OutlinedButton.icon(
            onPressed: () => push(context, const PartnerTrainerScreen()),
            icon: const Icon(Icons.sports_rounded),
            label: const Text('Set up trainer profile'),
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _loadTargets,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (targets.all.length > 1) ...[
            const SizedBox(height: 14),
            _TargetSwitcher(targets: targets.all, selected: _selected, onSelected: _select),
          ],
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _targetBody()),
        ],
      ),
    );
  }

  Widget _targetBody() {
    final target = _selected!;
    if (_loadingTarget || (_summary == null && _targetError == null)) {
      return const Padding(padding: EdgeInsets.only(top: 16), child: _RatingsSkeleton(embedded: true));
    }
    if (_targetError != null) {
      return Padding(padding: const EdgeInsets.only(top: 24), child: ErrorView(error: _targetError!, onRetry: _loadTarget));
    }
    final s = _summary!;
    final children = <Widget>[
      const SizedBox(height: 16),
      _HeroCard(target: target, summary: s),
    ];
    if (s.count == 0) {
      children.add(_NoRatingsYet(target: target, newUntil: s.newUntil));
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    }
    if (s.isNew) children.addAll([const SizedBox(height: 12), _NewProgress(summary: s)]);
    children.addAll([
      const SectionTitle('Star breakdown', padding: EdgeInsets.fromLTRB(0, 26, 0, 12)),
      _Histogram(summary: s),
      SectionTitle(
        'What members rate',
        subtitle: target.isTrainer ? 'Knowledge, punctuality, communication, results' : 'Optional details members add',
        padding: const EdgeInsets.fromLTRB(0, 26, 0, 12),
      ),
      _SubRatings(summary: s),
      const SectionTitle('Monthly trend', subtitle: 'Average stars, last 6 months', padding: EdgeInsets.fromLTRB(0, 26, 0, 12)),
      _TrendCard(trend: s.trend),
      _Tips(summary: s, trainer: target.isTrainer),
      SectionTitle('Recent ratings', subtitle: 'Members stay anonymous', padding: const EdgeInsets.fromLTRB(0, 26, 0, 12)),
      for (final r in _feed) Padding(padding: const EdgeInsets.only(bottom: 10), child: _RatingTile(r: r)),
      if (_next != null)
        Center(
          child: _loadingMore
              ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2.4))
              : TextButton.icon(
                  onPressed: _loadMore,
                  icon: const Icon(Icons.expand_more_rounded),
                  label: const Text('Show more ratings'),
                ),
        ),
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

String _targetImage(RatingTarget t) =>
    t.isTrainer ? AppImages.strength : venueVisual(t.categories.isEmpty ? 'gym' : t.categories.first).image;

Color _scoreColor(double v) => v >= 4 ? AppColors.green : (v >= 3 ? AppColors.amber : AppColors.red);

class _TargetSwitcher extends StatelessWidget {
  const _TargetSwitcher({required this.targets, required this.selected, required this.onSelected});
  final List<RatingTarget> targets;
  final RatingTarget? selected;
  final ValueChanged<RatingTarget> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: targets.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final t = targets[i];
          final on = t == selected;
          return Tap(
            onTap: () => onSelected(t),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
              constraints: const BoxConstraints(maxWidth: 240),
              decoration: BoxDecoration(
                color: on ? AppColors.ink : AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: on ? AppColors.ink : AppColors.line),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                t.isTrainer
                    ? PersonAvatar(name: t.name, photoUrl: t.photoUrl, size: 48)
                    : NetImage(t.photoUrl, fallback: _targetImage(t), width: 48, height: 48, radius: 12),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: on ? Colors.white : AppColors.text)),
                    const SizedBox(height: 2),
                    Text(
                      t.isNew ? 'New · ${t.count} rating${t.count == 1 ? '' : 's'}' : '${t.avg?.toStringAsFixed(1)} ★ · ${t.count}',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: on ? Colors.white70 : AppColors.text2),
                    ),
                  ]),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _Stars extends StatelessWidget {
  const _Stars(this.value, {this.size = 18});
  final double value;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 1; i <= 5; i++)
        Icon(
          value >= i ? Icons.star_rounded : (value >= i - 0.5 ? Icons.star_half_rounded : Icons.star_outline_rounded),
          size: size,
          color: AppColors.amber,
        ),
    ]);
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.target, required this.summary});
  final RatingTarget target;
  final RatingsSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final delta = s.last30Avg != null && s.previousAvg != null ? s.last30Avg! - s.previousAvg! : null;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SizedBox(
            height: 92,
            child: Stack(fit: StackFit.expand, children: [
              NetImage(target.isTrainer ? null : target.photoUrl, fallback: _targetImage(target)),
              const PhotoScrim(strength: 0.8, from: Alignment.topCenter),
              Positioned(
                left: 16,
                right: 16,
                bottom: 12,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(target.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18, letterSpacing: -0.3)),
                  if (target.subtitle.isNotEmpty)
                    Text(target.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12.5, fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(s.avg == null ? '–' : s.avg!.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 46, fontWeight: FontWeight.w800, letterSpacing: -1.5, height: 1)),
                const SizedBox(width: 4),
                const Text('/ 5', style: TextStyle(color: AppColors.text3, fontWeight: FontWeight.w700, fontSize: 15)),
              ]),
              const SizedBox(height: 6),
              _Stars(s.avg ?? 0, size: 20),
            ]),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                if (s.isNew)
                  const Tag('NEW', color: AppColors.blue, icon: Icons.auto_awesome_rounded)
                else
                  const Tag('RATED', color: AppColors.green, icon: Icons.verified_rounded),
                const SizedBox(height: 8),
                Text('${s.count} rating${s.count == 1 ? '' : 's'}',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 2),
                Text(
                  s.last30Count == 0 ? 'None in the last 30 days' : '${s.last30Count} in the last 30 days',
                  textAlign: TextAlign.end,
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                if (delta != null && delta.abs() >= 0.05) ...[
                  const SizedBox(height: 6),
                  Tag(
                    '${delta > 0 ? '▲' : '▼'} ${delta.abs().toStringAsFixed(1)} vs previous 30 days',
                    color: delta > 0 ? AppColors.green : AppColors.red,
                    dense: true,
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _NewProgress extends StatelessWidget {
  const _NewProgress({required this.summary});
  final RatingsSummary summary;

  @override
  Widget build(BuildContext context) {
    final left = summary.newUntil - summary.count;
    return AppCard(
      color: AppColors.blueSoft,
      shadow: false,
      child: Row(children: [
        const IconBubble(Icons.auto_awesome_rounded, color: AppColors.blue, bg: AppColors.surface),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$left more rating${left == 1 ? '' : 's'} to show your average',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            const SizedBox(height: 4),
            const Text('Members see "New" until you have 5 ratings.',
                style: TextStyle(color: AppColors.text2, fontSize: 12.5)),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: summary.count / summary.newUntil,
                minHeight: 8,
                color: AppColors.blue,
                backgroundColor: AppColors.surface,
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.color});
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 10,
      decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(6)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: fraction.clamp(0, 1).toDouble(),
        child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6))),
      ),
    );
  }
}

class _Histogram extends StatelessWidget {
  const _Histogram({required this.summary});
  final RatingsSummary summary;

  @override
  Widget build(BuildContext context) {
    final total = summary.count == 0 ? 1 : summary.count;
    return AppCard(
      child: Column(children: [
        for (var s = 5; s >= 1; s--)
          Padding(
            padding: EdgeInsets.only(bottom: s == 1 ? 0 : 10),
            child: Row(children: [
              SizedBox(
                width: 34,
                child: Row(children: [
                  Text('$s', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
                  const SizedBox(width: 2),
                  const Icon(Icons.star_rounded, size: 15, color: AppColors.amber),
                ]),
              ),
              Expanded(
                child: _Bar(
                  fraction: summary.distribution[s]! / total,
                  color: s >= 4 ? AppColors.green : (s == 3 ? AppColors.amber : AppColors.red),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text('${summary.distribution[s]}',
                    textAlign: TextAlign.end,
                    style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700, fontSize: 13)),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _SubRatings extends StatelessWidget {
  const _SubRatings({required this.summary});
  final RatingsSummary summary;

  @override
  Widget build(BuildContext context) {
    final keys = summary.subRatingKeys.isEmpty ? summary.subRatings.keys.toList() : summary.subRatingKeys;
    return AppCard(
      child: Column(children: [
        for (var i = 0; i < keys.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          _subRow(keys[i], summary.subRatings[keys[i]]),
        ],
      ]),
    );
  }

  Widget _subRow(String key, SubRatingStat? stat) {
    final label = subRatingLabels[key] ?? key;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5))),
        if (stat == null)
          const Text('Not rated yet', style: TextStyle(color: AppColors.text3, fontSize: 12.5, fontWeight: FontWeight.w600))
        else
          Text.rich(TextSpan(children: [
            TextSpan(
                text: stat.avg.toStringAsFixed(1),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: _scoreColor(stat.avg))),
            TextSpan(
                text: '  · ${stat.count}',
                style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
          ])),
      ]),
      const SizedBox(height: 6),
      _Bar(fraction: (stat?.avg ?? 0) / 5, color: stat == null ? AppColors.line : _scoreColor(stat.avg)),
    ]);
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.trend});
  final List<RatingTrendPoint> trend;

  static const _axis = TextStyle(color: AppColors.text3, fontSize: 11, fontWeight: FontWeight.w600);

  @override
  Widget build(BuildContext context) {
    final spots = [
      for (var i = 0; i < trend.length; i++)
        if (trend[i].avg != null) FlSpot(i.toDouble(), trend[i].avg!),
    ];
    return AppCard(
      padding: const EdgeInsets.fromLTRB(8, 18, 16, 10),
      child: SizedBox(
        height: 190,
        child: spots.isEmpty
            ? const Center(child: Text('No ratings in the last 6 months', style: TextStyle(color: AppColors.text2)))
            : LineChart(LineChartData(
                minX: 0,
                maxX: (trend.length - 1).toDouble().clamp(1, 12),
                minY: 0,
                maxY: 5,
                gridData: FlGridData(
                  drawVerticalLine: false,
                  horizontalInterval: 1,
                  getDrawingHorizontalLine: (_) => const FlLine(color: AppColors.line, strokeWidth: 1, dashArray: [4, 4]),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  rightTitles: const AxisTitles(),
                  topTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: 1,
                      getTitlesWidget: (v, _) => Text('${v.toInt()}★', style: _axis),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 1,
                      reservedSize: 24,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= trend.length || v != i.toDouble()) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(DateFormat('MMM').format(trend[i].month), style: _axis),
                        );
                      },
                    ),
                  ),
                ),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => AppColors.ink,
                    getTooltipItems: (items) => [
                      for (final it in items)
                        LineTooltipItem(
                          '${DateFormat('MMM yyyy').format(trend[it.x.toInt()].month)}\n',
                          const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                          children: [
                            TextSpan(
                              text: '${it.y.toStringAsFixed(1)}★ · ${trend[it.x.toInt()].count} rating'
                                  '${trend[it.x.toInt()].count == 1 ? '' : 's'}',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: spots.length > 2,
                    preventCurveOverShooting: true,
                    color: AppColors.amber,
                    barWidth: 3.5,
                    isStrokeCapRound: true,
                    dotData: FlDotData(
                      getDotPainter: (_, _, _, _) =>
                          FlDotCirclePainter(radius: 4.5, color: Colors.white, strokeWidth: 3, strokeColor: AppColors.amber),
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [AppColors.amber.withValues(alpha: 0.25), AppColors.amber.withValues(alpha: 0)],
                      ),
                    ),
                  ),
                ],
              )),
      ),
    );
  }
}

/// Practical, static advice for the lowest-scoring sub-ratings.
const _tips = <String, List<String>>{
  'cleanliness': [
    'Put a visible cleaning checklist near the front desk and sign it off every 2 hours.',
    'Keep wipes and sanitiser at every station and ask members to wipe down after use.',
    'Deep-clean washrooms and changing rooms before the morning and evening rush.',
  ],
  'equipment': [
    'Tag broken machines "Under repair" with a fix date — and fix them fast.',
    'Re-rack dumbbells and plates at shift change so the floor looks ready.',
    'Ask members which equipment they miss most; small additions go a long way.',
  ],
  'staff': [
    'Greet every member by name at check-in — the QR feed shows who just arrived.',
    'Keep a trainer on the floor at peak hours to help with form and machines.',
    'Brief staff weekly on member feedback and celebrate good ratings.',
  ],
  'crowd': [
    'Share your quieter hours with members so they can plan visits.',
    'Spread group classes away from the 6–8 pm rush.',
    'Host an off-peak event to pull visits to quieter slots.',
  ],
  'value': [
    'Show what is included — trainer help, lockers, showers — at the front desk.',
    'Run a free intro session or challenge for FitKey members.',
    'Keep amenities in your listing up to date so expectations match.',
  ],
  'knowledge': [
    'Explain the "why" behind each exercise during the session.',
    'Add your certifications to your trainer profile so members see your expertise.',
  ],
  'punctuality': [
    'Start on the booked slot — join online sessions 2 minutes early.',
    'If you are running late, message the member before the slot starts.',
  ],
  'communication': [
    'Agree on goals in the first 5 minutes and recap them at the end.',
    'Share a short plan or checklist after each session.',
  ],
  'results': [
    'Track a simple number with each member — reps, weight or minutes — and show progress.',
    'Set a 4-week goal together and check in on it every session.',
  ],
};

class _Tips extends StatelessWidget {
  const _Tips({required this.summary, required this.trainer});
  final RatingsSummary summary;
  final bool trainer;

  @override
  Widget build(BuildContext context) {
    final low = summary.subRatings.values.where((s) => s.avg < 4 && _tips.containsKey(s.key)).toList()
      ..sort((a, b) => a.avg.compareTo(b.avg));
    final avg = summary.avg ?? 0;
    if (low.isEmpty && avg >= 4) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: AppCard(
          color: AppColors.greenSoft,
          shadow: false,
          child: Row(children: [
            const IconBubble(Icons.celebration_rounded, color: AppColors.green, bg: AppColors.surface),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                trainer
                    ? 'Members love your sessions. Keep it up — consistent ratings rank you higher in Book a Trainer.'
                    : 'Members love this place. Keep it up — higher ratings rank you higher in Explore.',
                style: const TextStyle(fontWeight: FontWeight.w700, height: 1.35),
              ),
            ),
          ]),
        ),
      );
    }
    final picks = low.take(3).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Tips to improve', subtitle: 'Based on your lowest-rated areas', padding: EdgeInsets.fromLTRB(0, 26, 0, 12)),
      if (picks.isEmpty)
        _TipCard(
          title: 'Lift your overall rating',
          score: avg,
          tips: trainer
              ? const ['Ask happy clients to rate you after their session.', 'Start on time and share a plan after each session.']
              : const ['Ask happy members to rate you after their visit.', 'Keep the floor clean and staff visible at peak hours.'],
        ),
      for (final s in picks)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _TipCard(title: s.label, score: s.avg, tips: _tips[s.key]!),
        ),
    ]);
  }
}

class _TipCard extends StatelessWidget {
  const _TipCard({required this.title, required this.score, required this.tips});
  final String title;
  final double score;
  final List<String> tips;

  @override
  Widget build(BuildContext context) {
    final c = _scoreColor(score);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBubble(Icons.lightbulb_rounded, color: c, size: 36),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
          Tag('${score.toStringAsFixed(1)} ★', color: c),
        ]),
        const SizedBox(height: 10),
        for (final t in tips)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(t, style: const TextStyle(color: AppColors.text2, height: 1.4, fontSize: 13.5))),
            ]),
          ),
      ]),
    );
  }
}

class _RatingTile extends StatelessWidget {
  const _RatingTile({required this.r});
  final RatingEntry r;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          PersonAvatar(name: r.member, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.member, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
              Text('${formatShortDate(r.updatedAt)}${r.edited ? ' · edited' : ''}',
                  style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: _scoreColor(r.stars.toDouble()), borderRadius: BorderRadius.circular(8)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${r.stars}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
              const SizedBox(width: 2),
              const Icon(Icons.star_rounded, color: Colors.white, size: 14),
            ]),
          ),
        ]),
        if (r.subRatings.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final e in r.subRatings.entries)
              Tag('${subRatingLabels[e.key] ?? e.key} ${e.value}★', color: _scoreColor(e.value.toDouble()), dense: true),
          ]),
        ],
      ]),
    );
  }
}

class _NoRatingsYet extends StatelessWidget {
  const _NoRatingsYet({required this.target, required this.newUntil});
  final RatingTarget target;
  final int newUntil;

  @override
  Widget build(BuildContext context) {
    return EmptyView(
      icon: Icons.star_outline_rounded,
      color: AppColors.amber,
      title: 'No ratings yet — you\'re "New"',
      message: target.isTrainer
          ? 'Members can rate you after a session ends. Your average shows once you have $newUntil ratings.'
          : 'Members can rate ${target.name} after they check in. Your average shows once you have $newUntil ratings — '
              'every check-in is a chance for one.',
      action: SizedBox(
        width: 230,
        child: OutlinedButton.icon(
          onPressed: () => push(
            context,
            target.isTrainer
                ? const PartnerTrainerScreen()
                : CheckinCodeScreen(venueId: target.id, venueName: target.name),
          ),
          icon: Icon(target.isTrainer ? Icons.event_note_rounded : Icons.qr_code_2_rounded),
          label: Text(target.isTrainer ? 'View bookings' : 'Open check-in QR'),
        ),
      ),
    );
  }
}

class _RatingsSkeleton extends StatelessWidget {
  const _RatingsSkeleton({this.embedded = false});
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final boxes = [
      if (!embedded) ...[
        const Row(children: [
          SkeletonBox(height: 60, width: 170, radius: 16),
          SizedBox(width: 10),
          SkeletonBox(height: 60, width: 150, radius: 16),
        ]),
        const SizedBox(height: 16),
      ],
      const SkeletonBox(height: 200, radius: 20),
      const SizedBox(height: 26),
      const SkeletonBox(height: 18, width: 150),
      const SizedBox(height: 12),
      const SkeletonBox(height: 160, radius: 20),
      const SizedBox(height: 26),
      const SkeletonBox(height: 18, width: 170),
      const SizedBox(height: 12),
      const SkeletonBox(height: 190, radius: 20),
    ];
    final col = Column(crossAxisAlignment: CrossAxisAlignment.start, children: boxes);
    return Shimmer(
      child: embedded
          ? col
          : SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(), padding: const EdgeInsets.all(16), child: col),
    );
  }
}
