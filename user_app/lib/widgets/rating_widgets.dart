import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/ratings_api.dart';
import '../state/session.dart';
import '../ui/ui.dart';
import 'rating_prompt.dart';

/// Compact rating pill for cards: "4.3 ★ (128)" or "NEW". Renders nothing when [count] is null (rating unknown).
class RatingBadge extends StatelessWidget {
  const RatingBadge({super.key, required this.avg, required this.count, this.onPhoto = false, this.showCount = true});

  final double? avg;
  final int? count;

  /// White background variant for use on top of photos.
  final bool onPhoto;
  final bool showCount;

  @override
  Widget build(BuildContext context) {
    if (count == null) return const SizedBox.shrink();
    if (isNewRating(count) || avg == null) {
      return Tag('NEW', color: AppColors.blue, bg: onPhoto ? Colors.white : AppColors.blueSoft, icon: Icons.auto_awesome_rounded, dense: true);
    }
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(color: ratingColor(avg!), borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(avg!.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
        const SizedBox(width: 2),
        const Icon(Icons.star_rounded, color: Colors.white, size: 13),
      ]),
    );
    if (!showCount) return pill;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      pill,
      const SizedBox(width: 5),
      Text('${formatCount(count!)} rating${count == 1 ? '' : 's'}',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: onPhoto ? Colors.white : AppColors.text2)),
    ]);
  }
}

/// Zomato-style colour for an average.
Color ratingColor(double avg) => avg >= 4
    ? AppColors.green
    : avg >= 3
        ? const Color(0xFF6DAA2C)
        : avg >= 2
            ? AppColors.amber
            : AppColors.red;

String formatCount(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k' : '$n';

/// Row of tappable stars.
class StarInput extends StatelessWidget {
  const StarInput({super.key, required this.value, required this.onChanged, this.size = 44, this.spacing = 6});

  final int value;
  final ValueChanged<int> onChanged;
  final double size;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 1; i <= 5; i++)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: spacing / 2),
          child: Semantics(
            button: true,
            label: '$i star${i == 1 ? '' : 's'}',
            child: Tap(
              onTap: () => onChanged(i),
              scale: 0.85,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                child: Icon(
                  i <= value ? Icons.star_rounded : Icons.star_outline_rounded,
                  key: ValueKey(i <= value),
                  size: size,
                  color: i <= value ? AppColors.amber : AppColors.text3.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// "Ratings" section for a centre / trainer page: average, distribution, sub-ratings and a rate button
/// (enabled only for verified members — checked in / finished a session).
class RatingSummaryCard extends StatefulWidget {
  const RatingSummaryCard({
    super.key,
    required this.targetType,
    required this.targetId,
    required this.name,
    this.photoUrl,
    required this.fallbackImage,
    this.onChanged,
  });

  final String targetType; // venue | trainer
  final String targetId;
  final String name;
  final String? photoUrl;
  final String fallbackImage;

  /// Called after the member rates, with the new average / count.
  final void Function(double? avg, int count)? onChanged;

  @override
  State<RatingSummaryCard> createState() => _RatingSummaryCardState();
}

class _RatingSummaryCardState extends State<RatingSummaryCard> {
  late Future<RatingSummary> _future = _load();

  Future<RatingSummary> _load() => context.read<Session>().api.ratingSummary(widget.targetType, widget.targetId);

  Future<void> _rate(RatingSummary s) async {
    final res = await showRatingSheet(
      context,
      targetType: widget.targetType,
      targetId: widget.targetId,
      name: widget.name,
      photoUrl: widget.photoUrl,
      fallbackImage: widget.fallbackImage,
      initial: s.myRating,
    );
    if (res == null || !mounted) return;
    widget.onChanged?.call(res.avg, res.count);
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    final venue = widget.targetType == 'venue';
    return FutureBuilder<RatingSummary>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Shimmer(child: SkeletonBox(height: 150, radius: 20));
        }
        if (snap.hasError) {
          return AppCard(
            child: Row(children: [
              const IconBubble(Icons.star_outline_rounded, color: AppColors.amber, size: 38),
              const SizedBox(width: 12),
              const Expanded(
                child: Text("Couldn't load ratings", style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.text2)),
              ),
              TextButton(onPressed: () => setState(() => _future = _load()), child: const Text('Retry')),
            ]),
          );
        }
        final s = snap.data!;
        final labels = kSubRatingLabels[widget.targetType] ?? const {};
        final total = s.distribution.values.fold<int>(0, (a, b) => a + b);
        return AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 82,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: s.isNew ? AppColors.blueSoft : ratingColor(s.avg ?? 0).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(children: [
                  if (s.isNew) ...[
                    const Icon(Icons.auto_awesome_rounded, color: AppColors.blue, size: 26),
                    const SizedBox(height: 4),
                    const Text('New', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.blue)),
                  ] else ...[
                    Text(s.avg!.toStringAsFixed(1),
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 28, color: ratingColor(s.avg!), height: 1)),
                    const SizedBox(height: 4),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      for (var i = 1; i <= 5; i++)
                        Icon(i <= s.avg!.round() ? Icons.star_rounded : Icons.star_outline_rounded,
                            size: 12, color: AppColors.amber),
                    ]),
                  ],
                ]),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: s.isNew
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          s.count == 0
                              ? 'No ratings yet'
                              : '${s.count} rating${s.count == 1 ? '' : 's'} so far',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'The average appears after $kRatingsUntilAverage verified ${venue ? 'visits' : 'sessions'} are rated.',
                          style: const TextStyle(color: AppColors.text2, fontSize: 13, height: 1.4),
                        ),
                      ])
                    : Column(children: [
                        for (var star = 5; star >= 1; star--)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1.5),
                            child: Row(children: [
                              SizedBox(
                                width: 14,
                                child: Text('$star',
                                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.text2)),
                              ),
                              const Icon(Icons.star_rounded, size: 11, color: AppColors.text3),
                              const SizedBox(width: 6),
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: total == 0 ? 0 : (s.distribution[star] ?? 0) / total,
                                    minHeight: 6,
                                    backgroundColor: AppColors.surfaceAlt,
                                    color: ratingColor(star.toDouble()),
                                  ),
                                ),
                              ),
                            ]),
                          ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text('${s.count} verified rating${s.count == 1 ? '' : 's'}',
                              style: const TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
                        ),
                      ]),
              ),
            ]),
            if (!s.isNew && s.subRatings.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in labels.entries)
                  if (s.subRatings[e.key] != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(e.value, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 6),
                        Text(s.subRatings[e.key]!.toStringAsFixed(1),
                            style: TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w800, color: ratingColor(s.subRatings[e.key]!))),
                        const Icon(Icons.star_rounded, size: 13, color: AppColors.amber),
                      ]),
                    ),
              ]),
            ],
            const SizedBox(height: 14),
            if (s.canRate == true)
              OutlinedButton.icon(
                onPressed: () => _rate(s),
                icon: Icon(s.myRating == null ? Icons.star_rounded : Icons.edit_rounded, size: 18),
                label: Text(s.myRating == null
                    ? 'Rate this ${venue ? 'centre' : 'trainer'}'
                    : 'You rated ${s.myRating!.stars}★ · Update'),
              )
            else
              Row(children: [
                const Icon(Icons.verified_user_rounded, size: 16, color: AppColors.text3),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    venue
                        ? 'Only members who checked in here can rate this centre.'
                        : 'Only members who finished a session can rate this trainer.',
                    style: const TextStyle(fontSize: 12.5, color: AppColors.text3, fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
          ]),
        );
      },
    );
  }
}
