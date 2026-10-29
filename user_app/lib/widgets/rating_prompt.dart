import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/ratings_api.dart';
import '../state/session.dart';
import '../ui/ui.dart';
import 'rating_widgets.dart';

DateTime? _lastPrompt;
bool _prompting = false;

/// Shows the rating sheet for centres visited ≥ 1 h ago and trainer sessions that ended (BRD §8).
/// Safe to call on every Home load: runs at most once every 10 minutes, never stacks, and fails silently.
/// "Not now" is remembered server-side for that visit, so members aren't nagged.
Future<void> promptPendingRatings(BuildContext context) async {
  if (_prompting) return;
  final now = DateTime.now();
  if (_lastPrompt != null && now.difference(_lastPrompt!) < const Duration(minutes: 10)) return;
  _prompting = true;
  _lastPrompt = now;
  try {
    final api = context.read<Session>().api;
    final items = await api.pendingRatings();
    // Ask about at most two visits in one go; the rest come up next time.
    for (final p in items.take(2)) {
      if (!context.mounted) return;
      final res = await showRatingSheet(
        context,
        targetType: p.targetType,
        targetId: p.targetId,
        name: p.name,
        subtitle: p.subtitle,
        photoUrl: p.photoUrl,
        fallbackImage: p.targetType == 'venue'
            ? venueVisual(p.categories.isEmpty ? '' : p.categories.first).image
            : AppImages.homeWorkout,
        pending: p,
      );
      if (res == null) break; // dismissed — don't chain another sheet
    }
  } catch (_) {
    // A prompt is a nicety; never surface errors from it.
  } finally {
    _prompting = false;
  }
}

/// Opens the rating bottom sheet. Returns the new (avg, count) when a rating was saved, otherwise null.
/// With [pending], "Not now" is recorded server-side for that visit.
Future<({double? avg, int count})?> showRatingSheet(
  BuildContext context, {
  required String targetType,
  required String targetId,
  required String name,
  String? subtitle,
  String? photoUrl,
  required String fallbackImage,
  MyRating? initial,
  PendingRating? pending,
}) async {
  final api = context.read<Session>().api;
  final res = await showAppSheet<({double? avg, int count})>(
    context,
    builder: (_) => _RatingSheet(
      targetType: targetType,
      targetId: targetId,
      name: name,
      subtitle: subtitle,
      photoUrl: photoUrl,
      fallbackImage: fallbackImage,
      initial: initial,
    ),
  );
  if (res == null && pending != null) {
    try {
      await api.dismissRating(pending);
    } catch (_) {}
  }
  return res;
}

class _RatingSheet extends StatefulWidget {
  const _RatingSheet({
    required this.targetType,
    required this.targetId,
    required this.name,
    this.subtitle,
    this.photoUrl,
    required this.fallbackImage,
    this.initial,
  });

  final String targetType;
  final String targetId;
  final String name;
  final String? subtitle;
  final String? photoUrl;
  final String fallbackImage;
  final MyRating? initial;

  @override
  State<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<_RatingSheet> {
  late int _stars = widget.initial?.stars ?? 0;
  late final Map<String, int> _subs = {...?widget.initial?.subRatings};
  late bool _showDetails = _subs.isNotEmpty;
  bool _busy = false;

  static const _words = ['', 'Terrible', 'Bad', 'Okay', 'Good', 'Excellent!'];
  static const _emoji = ['', '😞', '🙁', '😐', '🙂', '🤩'];

  bool get _venue => widget.targetType == 'venue';

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final res = await context.read<Session>().api.submitRating(
            targetType: widget.targetType,
            targetId: widget.targetId,
            stars: _stars,
            subRatings: _subs,
          );
      if (!mounted) return;
      toast(context, _stars <= 2 ? 'Thanks — our team will look into this' : 'Thanks for rating!',
          icon: Icons.star_rounded);
      Navigator.pop(context, res);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = kSubRatingLabels[widget.targetType] ?? const {};
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: AppShadows.glow(AppColors.amber),
              border: Border.all(color: Colors.white, width: 3),
            ),
            child: ClipOval(child: NetImage(widget.photoUrl, fallback: widget.fallbackImage)),
          ),
          const SizedBox(height: 14),
          Text(
            _venue ? 'How was your visit?' : 'How was your session?',
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.4),
          ),
          const SizedBox(height: 4),
          Text(widget.name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.text2)),
          if (widget.subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(widget.subtitle!,
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, color: AppColors.text3)),
            ),
          const SizedBox(height: 18),
          StarInput(value: _stars, onChanged: (v) => setState(() => _stars = v), size: 48),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Text(
              _stars == 0 ? 'Tap a star to rate' : '${_emoji[_stars]}  ${_words[_stars]}',
              key: ValueKey(_stars),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: _stars == 0 ? AppColors.text3 : ratingColor(_stars.toDouble()),
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (_stars > 0) ...[
            Tap(
              onTap: () => setState(() => _showDetails = !_showDetails),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  const Icon(Icons.tune_rounded, size: 18, color: AppColors.text2),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _venue ? 'Rate cleanliness, equipment & more' : 'Rate knowledge, punctuality & more',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                    ),
                  ),
                  const Text('Optional', style: TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
                  Icon(_showDetails ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: AppColors.text2),
                ]),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: !_showDetails
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(children: [
                        for (final e in labels.entries)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(children: [
                              Expanded(
                                child: Text(e.value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                              ),
                              StarInput(
                                value: _subs[e.key] ?? 0,
                                size: 26,
                                spacing: 2,
                                onChanged: (v) => setState(() {
                                  if (_subs[e.key] == v) {
                                    _subs.remove(e.key); // tap the same star again to clear
                                  } else {
                                    _subs[e.key] = v;
                                  }
                                }),
                              ),
                            ]),
                          ),
                      ]),
                    ),
            ),
            const SizedBox(height: 16),
          ],
          AppButton(
            label: widget.initial == null ? 'Submit rating' : 'Update rating',
            icon: Icons.star_rounded,
            busy: _busy,
            onPressed: _stars == 0 ? null : _submit,
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(widget.initial == null ? 'Not now' : 'Cancel',
                style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700)),
          ),
          const Text('Only verified members can rate. Your name is never shown.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: AppColors.text3)),
        ]),
      ),
    );
  }
}
