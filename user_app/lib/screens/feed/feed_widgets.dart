import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/feed_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../../widgets/mini_markdown.dart';
import 'feed_profile_screen.dart';
import 'post_detail_screen.dart';

// ---------------------------------------------------------------------------
// Cross-screen sync: a like on the detail screen shows up on the feed card, etc.
// ---------------------------------------------------------------------------

sealed class FeedEvent {}

class PostChanged extends FeedEvent {
  PostChanged(this.post);
  final FeedPost post;
}

class PostDeleted extends FeedEvent {
  PostDeleted(this.id);
  final String id;
}

class PostCreated extends FeedEvent {
  PostCreated(this.post);
  final FeedPost post;
}

/// The author edited a post (content changed) — lists swap in the new object.
class PostEdited extends FeedEvent {
  PostEdited(this.post);
  final FeedPost post;
}

class FollowChanged extends FeedEvent {
  FollowChanged(this.userId, this.following);
  final String userId;
  final bool following;
}

class FeedBus {
  static final _c = StreamController<FeedEvent>.broadcast();
  static Stream<FeedEvent> get stream => _c.stream;
  static void emit(FeedEvent e) => _c.add(e);
}

/// Applies a [FeedEvent] to an in-memory list of posts. Returns true when something changed.
bool applyFeedEvent(List<FeedPost> posts, FeedEvent e) {
  switch (e) {
    case PostChanged(:final post):
      var hit = false;
      for (final p in posts) {
        if (p.id != post.id || identical(p, post)) continue;
        p
          ..liked = post.liked
          ..likeCount = post.likeCount
          ..saved = post.saved
          ..saveCount = post.saveCount
          ..commentCount = post.commentCount
          ..shareCount = post.shareCount;
        hit = true;
      }
      return hit;
    case PostDeleted(:final id):
      final before = posts.length;
      posts.removeWhere((p) => p.id == id);
      return posts.length != before;
    case FollowChanged(:final userId, :final following):
      var hit = false;
      for (final p in posts) {
        if (p.author.id == userId && p.author.following != following) {
          p.author.following = following;
          hit = true;
        }
      }
      return hit;
    case PostEdited(:final post):
      var hit = false;
      for (var i = 0; i < posts.length; i++) {
        if (posts[i].id == post.id) {
          posts[i] = post;
          hit = true;
        }
      }
      return hit;
    case PostCreated():
      return false;
  }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  if (d.inDays < 365) return '${(d.inDays / 7).floor()}w';
  return '${(d.inDays / 365).floor()}y';
}

String compactCount(int n) {
  if (n < 1000) return '$n';
  if (n < 100000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}K'.replaceAll('.0K', 'K');
  return '${(n / 100000).toStringAsFixed(1)}L'.replaceAll('.0L', 'L');
}

String kg(double v) => '${v % 1 == 0 ? v.toInt() : v.toStringAsFixed(1)} kg';

({IconData icon, Color color, String image}) categoryLook(String? c) => switch (c) {
      'gym' => (icon: Icons.fitness_center_rounded, color: AppColors.primary, image: AppImages.gym),
      'yoga' => (icon: Icons.self_improvement_rounded, color: AppColors.purple, image: AppImages.yoga),
      'nutrition' => (icon: Icons.restaurant_rounded, color: AppColors.green, image: AppImages.foodBowl),
      'weight_loss' => (icon: Icons.trending_down_rounded, color: AppColors.teal, image: AppImages.running),
      'weight_gain' => (icon: Icons.trending_up_rounded, color: AppColors.amber, image: AppImages.strength),
      'mental_wellness' => (icon: Icons.spa_rounded, color: AppColors.pink, image: AppImages.yoga),
      'sports' => (icon: Icons.sports_soccer_rounded, color: AppColors.blue, image: AppImages.sports),
      _ => (icon: Icons.dynamic_feed_rounded, color: AppColors.primary, image: AppImages.gymFloor),
    };

/// "Verified Trainer" / "Verified Nutritionist" / "Journey" badge.
class FeedBadgeTag extends StatelessWidget {
  const FeedBadgeTag(this.badge, {super.key, this.dense = true, this.iconOnly = false});
  final FeedBadge badge;
  final bool dense;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final look = switch (badge) {
      'trainer' => ('Verified Trainer', Icons.verified_rounded, AppColors.blue),
      'nutritionist' => ('Verified Nutritionist', Icons.verified_rounded, AppColors.green),
      'journey' => ('Journey', Icons.auto_graph_rounded, AppColors.purple),
      _ => null,
    };
    if (look == null) return const SizedBox.shrink();
    if (iconOnly) return Tooltip(message: look.$1, child: Icon(look.$2, size: 16, color: look.$3));
    return Tag(look.$1, icon: look.$2, color: look.$3, dense: dense);
  }
}

class PersonTap extends StatelessWidget {
  const PersonTap({super.key, required this.userId, required this.child});
  final String userId;
  final Widget child;
  @override
  Widget build(BuildContext context) => Tap(scale: 0.98, onTap: () => push(context, FeedProfileScreen(userId: userId)), child: child);
}

// ---------------------------------------------------------------------------
// Engagement actions (optimistic)
// ---------------------------------------------------------------------------

class FeedActions {
  static Future<void> toggleLike(BuildContext context, FeedPost post, VoidCallback refresh, {bool onlyLike = false}) async {
    if (post.isDraft) return;
    if (onlyLike && post.liked) return;
    final target = !post.liked;
    final api = context.read<Session>().api;
    post
      ..liked = target
      ..likeCount = (post.likeCount + (target ? 1 : -1)).clamp(0, 1 << 31);
    refresh();
    FeedBus.emit(PostChanged(post));
    try {
      final r = await api.setLike(post.id, target);
      post
        ..liked = r.liked
        ..likeCount = r.likeCount;
    } catch (e) {
      post
        ..liked = !target
        ..likeCount = (post.likeCount + (target ? -1 : 1)).clamp(0, 1 << 31);
      if (context.mounted) toast(context, friendlyError(e), error: true);
    }
    refresh();
    FeedBus.emit(PostChanged(post));
  }

  static Future<void> toggleSave(BuildContext context, FeedPost post, VoidCallback refresh) async {
    if (post.isDraft) return;
    final target = !post.saved;
    final api = context.read<Session>().api;
    post
      ..saved = target
      ..saveCount = (post.saveCount + (target ? 1 : -1)).clamp(0, 1 << 31);
    refresh();
    FeedBus.emit(PostChanged(post));
    HapticFeedback.selectionClick();
    try {
      final r = await api.setSave(post.id, target);
      post
        ..saved = r.saved
        ..saveCount = r.saveCount;
      if (context.mounted && target) toast(context, 'Saved to your collection', icon: Icons.bookmark_rounded);
    } catch (e) {
      post
        ..saved = !target
        ..saveCount = (post.saveCount + (target ? -1 : 1)).clamp(0, 1 << 31);
      if (context.mounted) toast(context, friendlyError(e), error: true);
    }
    refresh();
    FeedBus.emit(PostChanged(post));
  }

  /// Follow / unfollow with an optimistic flip. Returns the new state (or the old one on failure).
  static Future<bool> setFollow(BuildContext context, String userId, bool follow) async {
    final api = context.read<Session>().api;
    FeedBus.emit(FollowChanged(userId, follow));
    try {
      await api.setFollow(userId, follow);
      return follow;
    } catch (e) {
      FeedBus.emit(FollowChanged(userId, !follow));
      if (context.mounted) toast(context, friendlyError(e), error: true);
      return !follow;
    }
  }

  static String shareText(FeedPost p) {
    final who = p.author.displayName;
    final what = switch (p.kind) {
      'blog' => '“${p.title ?? 'A blog'}” by $who',
      'journey' => '$who\'s ${p.journey?.goalLabel.toLowerCase() ?? 'fitness'} journey'
          '${p.journey?.weightChange != null ? ' (${p.journey!.weightChange! > 0 ? '+' : ''}${kg(p.journey!.weightChange!)})' : ''}',
      _ => '$who on FitFeed${p.caption != null && p.caption!.isNotEmpty ? ': “${p.caption!.length > 90 ? '${p.caption!.substring(0, 90)}…' : p.caption}”' : ''}',
    };
    return '$what 💪\nSee it on FITKEY: ${p.shareUrl}';
  }

  static Future<void> share(BuildContext context, FeedPost post, VoidCallback refresh) async {
    if (post.isDraft) return;
    if (post.visibility != 'public') {
      toast(context, 'Followers-only posts can only be shared inside FITKEY', icon: Icons.lock_rounded);
    }
    await showAppSheet<void>(context, builder: (_) => _ShareSheet(post: post, onShared: refresh));
  }

  static Future<void> report(BuildContext context, FeedPost post) async {
    final api = context.read<Session>().api;
    final reason = await showAppSheet<String>(context, builder: (_) => const _ReportSheet());
    if (reason == null) return;
    try {
      await api.reportFeedPost(post.id, reason);
      if (context.mounted) toast(context, 'Thanks — our team will review this post');
    } catch (e) {
      if (context.mounted) toast(context, friendlyError(e), error: true);
    }
  }
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.post, required this.onShared});
  final FeedPost post;
  final VoidCallback onShared;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  late final Future<List<FeedPerson>> _people;
  final _picked = <String>{};
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<Session>();
    final me = s.user?.id;
    _people = me == null ? Future.value(const []) : s.api.followList(me, followers: false).then((r) => r.users);
  }

  Future<void> _record({List<String> to = const []}) async {
    final api = context.read<Session>().api;
    final r = await api.recordShare(widget.post.id, toUserIds: to);
    widget.post.shareCount = r.shareCount;
    widget.onShared();
    FeedBus.emit(PostChanged(widget.post));
  }

  Future<void> _systemShare() async {
    final post = widget.post;
    final nav = Navigator.of(context);
    try {
      final result = await SharePlus.instance.share(ShareParams(text: FeedActions.shareText(post), subject: post.title ?? 'FitFeed'));
      if (result.status != ShareResultStatus.dismissed) await _record();
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: post.shareUrl));
      if (mounted) toast(context, 'Link copied');
    }
    if (mounted) nav.pop();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: FeedActions.shareText(widget.post)));
    try {
      await _record();
    } catch (_) {}
    if (!mounted) return;
    toast(context, 'Link copied', icon: Icons.link_rounded);
    Navigator.pop(context);
  }

  Future<void> _sendInApp() async {
    setState(() => _sending = true);
    try {
      await _record(to: _picked.toList());
      if (!mounted) return;
      toast(context, 'Sent to ${_picked.length} ${_picked.length == 1 ? 'person' : 'people'}');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final public = widget.post.visibility == 'public';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Share post', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          if (public)
            Row(children: [
              Expanded(
                  child: _ShareOption(
                      icon: Icons.chat_rounded, label: 'WhatsApp', color: AppColors.green, onTap: _systemShare)),
              Expanded(
                  child: _ShareOption(
                      icon: Icons.camera_alt_rounded, label: 'Instagram', color: AppColors.pink, onTap: _systemShare)),
              Expanded(child: _ShareOption(icon: Icons.link_rounded, label: 'Copy link', color: AppColors.blue, onTap: _copy)),
              Expanded(
                  child: _ShareOption(icon: Icons.ios_share_rounded, label: 'More', color: AppColors.ink, onTap: _systemShare)),
            ]),
          const SizedBox(height: 18),
          const Text('Send in FITKEY', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
          const SizedBox(height: 4),
          const Text('People you follow get it in their notifications.', style: TextStyle(color: AppColors.text2, fontSize: 12.5)),
          const SizedBox(height: 10),
          FutureBuilder<List<FeedPerson>>(
            future: _people,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Shimmer(child: Row(children: [SkeletonBox(height: 72, width: 64), SizedBox(width: 10), SkeletonBox(height: 72, width: 64)]));
              }
              final people = snap.data ?? const <FeedPerson>[];
              if (people.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text('Follow people on FitFeed to send posts to them.', style: TextStyle(color: AppColors.text3)),
                );
              }
              return SizedBox(
                height: 92,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: people.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (_, i) {
                    final p = people[i];
                    final on = _picked.contains(p.id);
                    return Tap(
                      onTap: () => setState(() => on ? _picked.remove(p.id) : (_picked.length < 10 ? _picked.add(p.id) : null)),
                      child: SizedBox(
                        width: 64,
                        child: Column(children: [
                          Stack(children: [
                            PersonAvatar(name: p.displayName, photoUrl: p.avatarUrl, size: 56),
                            if (on)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  decoration: BoxDecoration(
                                      color: AppColors.primary, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                                  padding: const EdgeInsets.all(2),
                                  child: const Icon(Icons.check_rounded, size: 14, color: Colors.white),
                                ),
                              ),
                          ]),
                          const SizedBox(height: 6),
                          Text(p.displayName.split(' ').first,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    );
                  },
                ),
              );
            },
          ),
          if (_picked.isNotEmpty) ...[
            const SizedBox(height: 12),
            AppButton(label: 'Send to ${_picked.length}', icon: Icons.send_rounded, busy: _sending, onPressed: _sendInApp),
          ],
        ]),
      ),
    );
  }
}

class _ShareOption extends StatelessWidget {
  const _ShareOption({required this.icon, required this.label, required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tap(
        onTap: onTap,
        child: Column(children: [
          IconBubble(icon, color: color, size: 52),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      );
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet();
  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  static const _reasons = ['Spam or misleading', 'Nudity or sexual content', 'Harassment or hate', 'Unsafe fitness advice', 'Something else'];
  String? _reason;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Report post', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _reason,
            onChanged: (v) => setState(() => _reason = v),
            child: Column(children: [
              for (final r in _reasons)
                RadioListTile<String>(value: r, title: Text(r), contentPadding: EdgeInsets.zero, dense: true),
            ]),
          ),
          const SizedBox(height: 8),
          AppButton(
            label: 'Report',
            color: AppColors.red,
            onPressed: _reason == null ? null : () => Navigator.pop(context, _reason),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Media
// ---------------------------------------------------------------------------

/// Instagram-style photo carousel with page dots and a double-tap heart burst.
class PhotoCarousel extends StatefulWidget {
  const PhotoCarousel({super.key, required this.images, this.onDoubleTap, this.aspectRatio = 4 / 5, this.fallback = AppImages.gymFloor});
  final List<String> images;
  final VoidCallback? onDoubleTap;
  final double aspectRatio;
  final String fallback;

  @override
  State<PhotoCarousel> createState() => _PhotoCarouselState();
}

class _PhotoCarouselState extends State<PhotoCarousel> {
  int _page = 0;
  final _heart = GlobalKey<HeartBurstState>();

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: GestureDetector(
        onDoubleTap: widget.onDoubleTap == null
            ? null
            : () {
                _heart.currentState?.burst();
                widget.onDoubleTap!();
              },
        child: Stack(fit: StackFit.expand, children: [
          PageView.builder(
            itemCount: images.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => NetImage(images[i], fallback: widget.fallback),
          ),
          if (images.length > 1) ...[
            Positioned(
              top: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(20)),
                child: Text('${_page + 1}/${images.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
              ),
            ),
            Positioned(
              bottom: 10,
              left: 0,
              right: 0,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < images.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 2.5),
                    width: i == _page ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: i == _page ? 1 : 0.6),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ]),
            ),
          ],
          IgnorePointer(child: Center(child: HeartBurst(key: _heart))),
        ]),
      ),
    );
  }
}

/// A big white heart that pops and fades — call [HeartBurstState.burst].
class HeartBurst extends StatefulWidget {
  const HeartBurst({super.key, this.size = 96});
  final double size;
  @override
  State<HeartBurst> createState() => HeartBurstState();
}

class HeartBurstState extends State<HeartBurst> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 750));

  void burst() {
    HapticFeedback.lightImpact();
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        if (_c.value == 0 || _c.value == 1) return const SizedBox.shrink();
        final t = _c.value;
        final scale = t < 0.3 ? Curves.easeOutBack.transform(t / 0.3) * 1.15 : 1.15 - 0.15 * ((t - 0.3) / 0.7);
        final opacity = t < 0.7 ? 1.0 : 1 - (t - 0.7) / 0.3;
        return Opacity(
          opacity: opacity.clamp(0, 1),
          child: Transform.scale(
            scale: scale,
            child: Icon(Icons.favorite_rounded,
                size: widget.size, color: Colors.white, shadows: const [Shadow(color: Color(0x55000000), blurRadius: 24)]),
          ),
        );
      },
    );
  }
}

/// Drag-to-compare before / after slider.
class BeforeAfterSlider extends StatefulWidget {
  const BeforeAfterSlider({super.key, required this.beforeUrl, required this.afterUrl, this.aspectRatio = 4 / 5, this.onDoubleTap});
  final String? beforeUrl;
  final String? afterUrl;
  final double aspectRatio;
  final VoidCallback? onDoubleTap;

  @override
  State<BeforeAfterSlider> createState() => _BeforeAfterSliderState();
}

class _BeforeAfterSliderState extends State<BeforeAfterSlider> {
  double _split = 0.5;
  final _heart = GlobalKey<HeartBurstState>();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: LayoutBuilder(builder: (context, box) {
        void drag(Offset local) => setState(() => _split = (local.dx / box.maxWidth).clamp(0.04, 0.96));
        return GestureDetector(
          onHorizontalDragStart: (d) => drag(d.localPosition),
          onHorizontalDragUpdate: (d) => drag(d.localPosition),
          onTapUp: (d) => drag(d.localPosition),
          onDoubleTap: widget.onDoubleTap == null
              ? null
              : () {
                  _heart.currentState?.burst();
                  widget.onDoubleTap!();
                },
          child: Stack(fit: StackFit.expand, children: [
            NetImage(widget.afterUrl, fallback: AppImages.strength),
            ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: _split,
                child: SizedBox(
                  width: box.maxWidth,
                  height: box.maxHeight,
                  child: NetImage(widget.beforeUrl, fallback: AppImages.gymFloor),
                ),
              ),
            ),
            Positioned(left: 12, top: 12, child: _label('BEFORE')),
            Positioned(right: 12, top: 12, child: _label('AFTER')),
            Positioned(
              left: box.maxWidth * _split - 1.5,
              top: 0,
              bottom: 0,
              child: Container(width: 3, color: Colors.white),
            ),
            Positioned(
              left: box.maxWidth * _split - 20,
              top: box.maxHeight / 2 - 20,
              child: Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: AppShadows.card),
                child: const Icon(Icons.compare_arrows_rounded, color: AppColors.ink),
              ),
            ),
            IgnorePointer(child: Center(child: HeartBurst(key: _heart))),
          ]),
        );
      }),
    );
  }

  Widget _label(String s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(8)),
        child: Text(s, style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1)),
      );
}

/// Start → current stats for a journey.
class JourneyStatsRow extends StatelessWidget {
  const JourneyStatsRow({super.key, required this.journey});
  final JourneyData journey;

  @override
  Widget build(BuildContext context) {
    final j = journey;
    final change = j.weightChange;
    final good = change == null ? null : (j.goal == 'weight_gain' ? change > 0 : change < 0);
    Widget cell(String label, String value, {Color? color}) => Expanded(
          child: Column(children: [
            Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color ?? AppColors.text)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
          ]),
        );
    final cells = <Widget>[
      if (j.start.weightKg != null) cell('Start', kg(j.start.weightKg!)),
      if (j.current.weightKg != null) cell('Now', kg(j.current.weightKg!)),
      if (change != null)
        cell('Change', '${change > 0 ? '+' : ''}${kg(change)}', color: good == true ? AppColors.green : AppColors.amber),
      if (j.start.weightKg == null && j.current.bodyFatPct != null) cell('Body fat', '${j.current.bodyFatPct!.toStringAsFixed(1)}%'),
      if (j.current.calories != null) cell('Daily kcal', '${j.current.calories}'),
    ];
    if (cells.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(color: AppColors.purpleSoft, borderRadius: BorderRadius.circular(16)),
      child: Row(children: cells),
    );
  }
}

/// Blog body: light Markdown (headings, bold, bullets) with inline `![](url)` images.
class BlogBody extends StatelessWidget {
  const BlogBody(this.markdown, {super.key});
  final String markdown;

  static final _image = RegExp(r'^\s*!\[[^\]]*\]\(([^)\s]+)\)\s*$');

  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[];
    final buffer = StringBuffer();
    void flush() {
      final t = buffer.toString().trim();
      if (t.isNotEmpty) {
        blocks.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: MiniMarkdown(t, fontSize: 16.5, color: AppColors.text),
        ));
      }
      buffer.clear();
    }

    for (final line in markdown.split('\n')) {
      final m = _image.firstMatch(line);
      if (m != null) {
        flush();
        blocks.add(Padding(
          padding: const EdgeInsets.only(bottom: 16, top: 4),
          child: NetImage(m.group(1), fallback: AppImages.gymFloor, radius: 16, height: 240),
        ));
      } else {
        buffer.writeln(line);
      }
    }
    flush();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: blocks);
  }
}

// ---------------------------------------------------------------------------
// Post card
// ---------------------------------------------------------------------------

class PostHeader extends StatelessWidget {
  const PostHeader({super.key, required this.post, this.onMenu, this.showFollow = true});
  final FeedPost post;
  final VoidCallback? onMenu;
  final bool showFollow;

  @override
  Widget build(BuildContext context) {
    final a = post.author;
    final look = categoryLook(post.category);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
      child: Row(children: [
        PersonTap(
          userId: a.id,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: a.badge == null ? null : AppColors.primaryGradient,
              color: a.badge == null ? AppColors.line : null,
            ),
            child: Container(
              padding: const EdgeInsets.all(1.5),
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: PersonAvatar(name: a.displayName, photoUrl: a.avatarUrl, size: 38),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: PersonTap(
            userId: a.id,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(a.displayName,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                ),
                if (a.badge == 'trainer' || a.badge == 'nutritionist') ...[
                  const SizedBox(width: 4),
                  FeedBadgeTag(a.badge, iconOnly: true),
                ],
              ]),
              const SizedBox(height: 2),
              Row(children: [
                if (a.badge != null) ...[FeedBadgeTag(a.badge), const SizedBox(width: 6)],
                Flexible(
                  child: Text(
                    [
                      if (post.category != null) feedCategories[post.category] ?? '',
                      post.isDraft ? 'Draft' : timeAgo(post.time),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: post.category != null ? look.color : AppColors.text3, fontWeight: FontWeight.w600),
                  ),
                ),
                if (post.visibility == 'followers') ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.group_rounded, size: 13, color: AppColors.text3),
                ],
              ]),
            ]),
          ),
        ),
        if (showFollow && !post.isMine && !a.following) _FollowPill(author: a),
        if (onMenu != null) IconButton(onPressed: onMenu, icon: const Icon(Icons.more_horiz_rounded, color: AppColors.text2)),
      ]),
    );
  }
}

class _FollowPill extends StatelessWidget {
  const _FollowPill({required this.author});
  final FeedAuthor author;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: () => FeedActions.setFollow(context, author.id, true),
      child: Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(10)),
        child: const Text('Follow', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 12.5)),
      ),
    );
  }
}

/// Like · comment · share … save.
class PostActionsBar extends StatelessWidget {
  const PostActionsBar({super.key, required this.post, required this.refresh, this.onComment});
  final FeedPost post;
  final VoidCallback refresh;
  final VoidCallback? onComment;

  @override
  Widget build(BuildContext context) {
    final disabled = post.isDraft;
    Widget btn(IconData icon, Color color, String? count, VoidCallback? onTap, {String? tooltip}) => Tap(
          onTap: disabled ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(children: [
              Icon(icon, size: 25, color: disabled ? AppColors.text3 : color),
              if (count != null) ...[
                const SizedBox(width: 5),
                Text(count, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              ],
            ]),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
          child: KeyedSubtree(
            key: ValueKey(post.liked),
            child: btn(post.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, post.liked ? AppColors.red : AppColors.text,
                compactCount(post.likeCount), () => FeedActions.toggleLike(context, post, refresh)),
          ),
        ),
        btn(Icons.chat_bubble_outline_rounded, AppColors.text, compactCount(post.commentCount), onComment),
        btn(Icons.send_rounded, AppColors.text, post.shareCount > 0 ? compactCount(post.shareCount) : null,
            () => FeedActions.share(context, post, refresh)),
        const Spacer(),
        btn(post.saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded, post.saved ? AppColors.primary : AppColors.text, null,
            () => FeedActions.toggleSave(context, post, refresh)),
      ]),
    );
  }
}

/// Expandable caption: "name caption… more".
class PostCaption extends StatefulWidget {
  const PostCaption({super.key, required this.post, this.expanded = false});
  final FeedPost post;
  final bool expanded;
  @override
  State<PostCaption> createState() => _PostCaptionState();
}

class _PostCaptionState extends State<PostCaption> {
  late bool _open = widget.expanded;

  @override
  Widget build(BuildContext context) {
    final c = widget.post.caption;
    if (c == null || c.trim().isEmpty) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '${widget.post.author.displayName.split(' ').first}  ', style: const TextStyle(fontWeight: FontWeight.w800)),
            TextSpan(text: c),
          ]),
          maxLines: _open ? null : 3,
          overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, height: 1.45, color: AppColors.text),
        ),
      ),
    );
  }
}

class PostCard extends StatefulWidget {
  const PostCard({super.key, required this.post, this.onMenu});
  final FeedPost post;

  /// Optional owner / report menu handler.
  final void Function(FeedPost post)? onMenu;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  void _refresh() {
    if (mounted) setState(() {});
  }

  void _open() => push(context, PostDetailScreen(postId: widget.post.id));

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    void like() => FeedActions.toggleLike(context, p, _refresh, onlyLike: true);
    final Widget media = switch (p.kind) {
      'journey' => BeforeAfterSlider(beforeUrl: p.journey?.beforeUrl, afterUrl: p.journey?.afterUrl, onDoubleTap: like),
      'blog' => _BlogPreview(post: p, onTap: _open),
      _ => PhotoCarousel(images: p.images, onDoubleTap: like, fallback: categoryLook(p.category).image),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(22), boxShadow: AppShadows.card),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PostHeader(post: p, onMenu: widget.onMenu == null ? null : () => widget.onMenu!(p)),
        media,
        if (p.kind == 'journey' && p.journey != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Tap(onTap: _open, child: JourneyStatsRow(journey: p.journey!)),
          ),
        const SizedBox(height: 4),
        PostActionsBar(post: p, refresh: _refresh, onComment: _open),
        if (p.kind != 'blog') PostCaption(post: p),
        if (p.commentCount > 0)
          Tap(
            onTap: _open,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
              child: Text('View ${p.commentCount == 1 ? '1 comment' : 'all ${p.commentCount} comments'}',
                  style: const TextStyle(color: AppColors.text3, fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          ),
        if (p.kind == 'journey')
          Tap(
            onTap: _open,
            child: const Padding(
              padding: EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: Text('See full journey →', style: TextStyle(color: AppColors.purple, fontWeight: FontWeight.w800, fontSize: 13)),
            ),
          ),
        const SizedBox(height: 14),
      ]),
    );
  }
}

class _BlogPreview extends StatelessWidget {
  const _BlogPreview({required this.post, required this.onTap});
  final FeedPost post;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final look = categoryLook(post.category);
    return Tap(
      scale: 0.99,
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(fit: StackFit.expand, children: [
            NetImage(post.coverUrl, fallback: look.image),
            const PhotoScrim(strength: 0.35),
            Positioned(
              left: 12,
              bottom: 12,
              child: Tag('${post.readMinutes ?? 1} min read', icon: Icons.menu_book_rounded, color: AppColors.ink, bg: Colors.white),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(post.title ?? 'Untitled',
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, height: 1.25, letterSpacing: -0.4)),
            if ((post.excerpt ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(post.excerpt!,
                  maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2, height: 1.45, fontSize: 14)),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Feed-card shaped skeleton.
class PostSkeleton extends StatelessWidget {
  const PostSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(22), boxShadow: AppShadows.soft),
      clipBehavior: Clip.antiAlias,
      child: const Shimmer(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: EdgeInsets.all(14),
            child: Row(children: [
              SkeletonBox(height: 40, width: 40, radius: 20),
              SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SkeletonBox(height: 13, width: 130),
                SizedBox(height: 6),
                SkeletonBox(height: 10, width: 80),
              ]),
            ]),
          ),
          AspectRatio(aspectRatio: 1, child: SkeletonBox(radius: 0)),
          Padding(
            padding: EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SkeletonBox(height: 14, width: 160),
              SizedBox(height: 8),
              SkeletonBox(height: 12, width: 240),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Square grid tile for profile / saved grids.
class PostGridTile extends StatelessWidget {
  const PostGridTile({super.key, required this.post});
  final FeedPost post;

  @override
  Widget build(BuildContext context) {
    final icon = switch (post.kind) {
      'blog' => Icons.article_rounded,
      'journey' => Icons.compare_rounded,
      _ => post.images.length > 1 ? Icons.collections_rounded : null,
    };
    return Tap(
      scale: 0.98,
      onTap: () => push(context, PostDetailScreen(postId: post.id)),
      child: Stack(fit: StackFit.expand, children: [
        NetImage(post.thumbnail, fallback: categoryLook(post.category).image),
        if (post.kind == 'blog') ...[
          const PhotoScrim(strength: 0.8),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Text(post.title ?? '',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12, height: 1.25)),
          ),
        ],
        if (icon != null)
          Positioned(top: 6, right: 6, child: Icon(icon, color: Colors.white, size: 18, shadows: const [Shadow(blurRadius: 6)])),
      ]),
    );
  }
}
