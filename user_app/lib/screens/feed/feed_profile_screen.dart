import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/feed_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../trainers/trainer_detail_screen.dart';
import 'feed_lists_screen.dart';
import 'feed_screen.dart' show PersonRow, openCreatePost;
import 'feed_widgets.dart';

/// Public FitFeed profile: posts, journeys, follower / following counts, badge and follow button.
class FeedProfileScreen extends StatefulWidget {
  const FeedProfileScreen({super.key, required this.userId});
  final String userId;

  @override
  State<FeedProfileScreen> createState() => _FeedProfileScreenState();
}

class _FeedProfileScreenState extends State<FeedProfileScreen> {
  FeedProfile? _profile;
  Object? _error;
  String? _kind; // null = all posts, 'journey'
  final _posts = <FeedPost>[];
  String? _cursor;
  bool _postsLoading = true;
  bool _loadingMore = false;
  bool _followBusy = false;
  final _scroll = ScrollController();
  StreamSubscription<FeedEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _loadMore();
    });
    _sub = FeedBus.stream.listen((e) {
      if (!mounted) return;
      if (e is PostCreated && _profile?.isMe == true) {
        _load();
      } else if (applyFeedEvent(_posts, e)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<Session>().api;
    setState(() => _error = null);
    try {
      final results = await Future.wait([api.feedProfile(widget.userId), api.userFeedPosts(widget.userId, kind: _kind)]);
      if (!mounted) return;
      final page = results[1] as FeedPage;
      setState(() {
        _profile = results[0] as FeedProfile;
        _posts
          ..clear()
          ..addAll(page.posts);
        _cursor = page.nextCursor;
        _postsLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _setKind(String? kind) async {
    if (kind == _kind) return;
    final api = context.read<Session>().api;
    setState(() {
      _kind = kind;
      _postsLoading = true;
    });
    try {
      final page = await api.userFeedPosts(widget.userId, kind: kind);
      if (!mounted || kind != _kind) return;
      setState(() {
        _posts
          ..clear()
          ..addAll(page.posts);
        _cursor = page.nextCursor;
        _postsLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _postsLoading = false);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _postsLoading || _cursor == null) return;
    final api = context.read<Session>().api;
    setState(() => _loadingMore = true);
    try {
      final page = await api.userFeedPosts(widget.userId, kind: _kind, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _posts.addAll(page.posts.where((p) => !_posts.any((x) => x.id == p.id)));
        _cursor = page.nextCursor;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _toggleFollow() async {
    final p = _profile!;
    final target = !p.isFollowing;
    setState(() {
      _followBusy = true;
      p.isFollowing = target;
      p.followers += target ? 1 : -1;
    });
    final result = await FeedActions.setFollow(context, p.id, target);
    if (!mounted) return;
    setState(() {
      _followBusy = false;
      if (result != target) {
        p.isFollowing = result;
        p.followers += target ? -1 : 1;
      }
    });
  }

  Future<void> _editBio() async {
    final p = _profile!;
    final controller = TextEditingController(text: p.bio ?? '');
    final bio = await showAppSheet<String>(
      context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Your FitFeed bio', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 3,
              maxLength: 300,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'e.g. Powerlifter · 6am gym crew · learning to love veggies'),
            ),
            const SizedBox(height: 10),
            AppButton(label: 'Save', onPressed: () => Navigator.pop(ctx, controller.text.trim())),
          ]),
        ),
      ),
    );
    controller.dispose();
    if (bio == null || !mounted) return;
    try {
      final updated = await context.read<Session>().api.updateFeedBio(bio.isEmpty ? null : bio);
      if (mounted) setState(() => _profile = updated);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    if (p == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: _error != null ? ErrorView(error: _error!, onRetry: _load) : const _ProfileSkeleton(),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(p.isMe ? 'My FitFeed' : p.displayName)),
      floatingActionButton: p.isMe
          ? FloatingActionButton(
              heroTag: 'fitfeed-profile-create',
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              onPressed: () => openCreatePost(context),
              child: const Icon(Icons.add_rounded),
            )
          : null,
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: CustomScrollView(controller: _scroll, physics: const AlwaysScrollableScrollPhysics(), slivers: [
          SliverToBoxAdapter(child: _header(p)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 18, 0, 12),
              child: ChoiceChips<String?>(
                options: const [null, 'journey', 'blog', 'photo'],
                selected: _kind,
                onSelected: _setKind,
                label: (k) => switch (k) {
                  'journey' => 'Journeys · ${p.journeyCount}',
                  'blog' => 'Blogs',
                  'photo' => 'Photos',
                  _ => 'All posts · ${p.postCount}',
                },
                icon: (k) => switch (k) {
                  'journey' => Icons.compare_rounded,
                  'blog' => Icons.article_rounded,
                  'photo' => Icons.photo_rounded,
                  _ => Icons.grid_view_rounded,
                },
              ),
            ),
          ),
          if (_postsLoading)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid.count(
                crossAxisCount: 3,
                mainAxisSpacing: 3,
                crossAxisSpacing: 3,
                children: List.generate(6, (_) => const Shimmer(child: SkeletonBox(radius: 0))),
              ),
            )
          else if (_posts.isEmpty)
            SliverToBoxAdapter(
              child: EmptyView(
                icon: _kind == 'journey' ? Icons.compare_rounded : Icons.photo_library_outlined,
                title: p.isMe ? 'Share your first post' : 'No posts yet',
                message: p.isMe ? 'Your photos, blogs and journeys will show here.' : '${p.displayName} hasn\'t shared anything here yet.',
                action: p.isMe
                    ? SizedBox(width: 180, child: AppButton(label: 'Create post', icon: Icons.add_rounded, onPressed: () => openCreatePost(context)))
                    : null,
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverToBoxAdapter(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    itemCount: _posts.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 3, crossAxisSpacing: 3),
                    itemBuilder: (_, i) => PostGridTile(post: _posts[i]),
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: _loadingMore
                ? const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                : const SizedBox(height: 100),
          ),
        ]),
      ),
    );
  }

  Widget _header(FeedProfile p) {
    Widget count(String label, int n, VoidCallback? onTap) => Expanded(
          child: Tap(
            onTap: onTap,
            child: Column(children: [
              Text(compactCount(n), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
            ]),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: AppCard(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: p.badge == null ? null : AppColors.primaryGradient,
                color: p.badge == null ? AppColors.line : null,
              ),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: PersonAvatar(name: p.displayName, photoUrl: p.avatarUrl, size: 78),
              ),
            ),
            const SizedBox(width: 8),
            count('Posts', p.postCount, null),
            count('Followers', p.followers, () => push(context, FollowListScreen(userId: p.id, followers: true, name: p.displayName))),
            count('Following', p.following, () => push(context, FollowListScreen(userId: p.id, followers: false, name: p.displayName))),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Flexible(
              child: Text(p.displayName,
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (p.badge == 'trainer' || p.badge == 'nutritionist') ...[const SizedBox(width: 5), FeedBadgeTag(p.badge, iconOnly: true)],
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (p.badge != null) FeedBadgeTag(p.badge, dense: false),
            if (p.city != null) Tag(p.city!, icon: Icons.location_on_rounded, color: AppColors.text2),
            if (p.followsMe && !p.isMe) const Tag('Follows you', color: AppColors.text2),
          ]),
          if ((p.bio ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(p.bio!, style: const TextStyle(height: 1.45, color: AppColors.text)),
          ],
          const SizedBox(height: 16),
          if (p.isMe)
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                    onPressed: _editBio, icon: const Icon(Icons.edit_rounded, size: 18), label: Text(p.bio == null ? 'Add bio' : 'Edit bio')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                    onPressed: () => push(context, const DraftsScreen()),
                    icon: const Icon(Icons.drafts_outlined, size: 18),
                    label: const Text('Drafts')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                    onPressed: () => push(context, const SavedPostsScreen()),
                    icon: const Icon(Icons.bookmark_border_rounded, size: 18),
                    label: const Text('Saved')),
              ),
            ])
          else
            SizedBox(
              width: double.infinity,
              height: 46,
              child: p.isFollowing
                  ? OutlinedButton(onPressed: _followBusy ? null : _toggleFollow, child: const Text('Following'))
                  : FilledButton.icon(
                      onPressed: _followBusy ? null : _toggleFollow,
                      icon: const Icon(Icons.person_add_alt_1_rounded, size: 19),
                      label: Text(p.followsMe ? 'Follow back' : 'Follow'),
                    ),
            ),
          if (p.trainerId != null) ...[
            const SizedBox(height: 12),
            Tap(
              onTap: () => push(context, TrainerDetailScreen(trainerId: p.trainerId!)),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(16)),
                child: Row(children: [
                  const IconBubble(Icons.sports_rounded, color: AppColors.blue, bg: Colors.white, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.isMe ? 'Your trainer profile' : 'Book a session', style: const TextStyle(fontWeight: FontWeight.w800)),
                      const Text('See rates, modes and open slots', style: TextStyle(fontSize: 12.5, color: AppColors.text2)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.blue),
                ]),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            SkeletonBox(height: 84, width: 84, radius: 42),
            SizedBox(width: 20),
            Expanded(child: SkeletonBox(height: 40)),
          ]),
          SizedBox(height: 16),
          SkeletonBox(height: 18, width: 160),
          SizedBox(height: 10),
          SkeletonBox(height: 12, width: 240),
          SizedBox(height: 18),
          SkeletonBox(height: 46),
          SizedBox(height: 24),
          SkeletonBox(height: 220),
        ]),
      ),
    );
  }
}

/// Followers / following of a user.
class FollowListScreen extends StatefulWidget {
  const FollowListScreen({super.key, required this.userId, required this.followers, required this.name});
  final String userId;
  final bool followers;
  final String name;

  @override
  State<FollowListScreen> createState() => _FollowListScreenState();
}

class _FollowListScreenState extends State<FollowListScreen> {
  final _people = <FeedPerson>[];
  String? _cursor;
  bool _loading = true;
  bool _more = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    final api = context.read<Session>().api;
    setState(() {
      if (more) {
        _more = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final r = await api.followList(widget.userId, followers: widget.followers, cursor: more ? _cursor : null);
      if (!mounted) return;
      setState(() {
        if (!more) _people.clear();
        _people.addAll(r.users);
        _cursor = r.nextCursor;
        _loading = false;
        _more = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _more = false;
          if (!more) _error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.followers ? 'Followers' : 'Following')),
      body: _loading
          ? const SkeletonList(itemHeight: 52)
          : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : _people.isEmpty
                  ? EmptyView(
                      icon: Icons.group_outlined,
                      title: widget.followers ? 'No followers yet' : 'Not following anyone yet',
                      message: widget.followers ? 'When people follow ${widget.name}, they show up here.' : null,
                    )
                  : RefreshIndicator(
                      color: AppColors.primary,
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _people.length + (_cursor != null ? 1 : 0),
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          if (i == _people.length) {
                            return Center(
                              child: _more
                                  ? const CircularProgressIndicator(strokeWidth: 2)
                                  : TextButton(onPressed: () => _load(more: true), child: const Text('Load more')),
                            );
                          }
                          return PersonRow(person: _people[i], onChanged: () => setState(() {}));
                        },
                      ),
                    ),
    );
  }
}
