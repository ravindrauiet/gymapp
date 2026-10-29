import 'dart:async';
import 'package:fitkey_core/fitkey_core.dart' show formatShortDate;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/feed_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'compose_screen.dart';
import 'feed_widgets.dart';

/// Posts I saved, newest save first (cursor pagination).
class SavedPostsScreen extends StatefulWidget {
  const SavedPostsScreen({super.key});

  @override
  State<SavedPostsScreen> createState() => _SavedPostsScreenState();
}

class _SavedPostsScreenState extends State<SavedPostsScreen> {
  final _posts = <FeedPost>[];
  String? _cursor;
  bool _loading = true;
  bool _more = false;
  Object? _error;
  final _scroll = ScrollController();
  StreamSubscription<FeedEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 500) _loadMore();
    });
    _sub = FeedBus.stream.listen((e) {
      if (!mounted) return;
      if (e is PostChanged && !e.post.saved) {
        setState(() => _posts.removeWhere((p) => p.id == e.post.id));
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
      final page = await api.savedPosts();
      if (!mounted) return;
      setState(() {
        _posts
          ..clear()
          ..addAll(page.posts);
        _cursor = page.nextCursor;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_more || _loading || _cursor == null) return;
    final api = context.read<Session>().api;
    setState(() => _more = true);
    try {
      final page = await api.savedPosts(cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _posts.addAll(page.posts.where((p) => !_posts.any((x) => x.id == p.id)));
        _cursor = page.nextCursor;
        _more = false;
      });
    } catch (_) {
      if (mounted) setState(() => _more = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saved')),
      body: _loading
          ? Shimmer(
              child: GridView.count(
                padding: const EdgeInsets.all(16),
                crossAxisCount: 3,
                mainAxisSpacing: 3,
                crossAxisSpacing: 3,
                children: List.generate(9, (_) => const SkeletonBox(radius: 0)),
              ),
            )
          : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  color: AppColors.primary,
                  onRefresh: _load,
                  child: _posts.isEmpty
                      ? ListView(children: const [
                          EmptyView(
                            icon: Icons.bookmark_border_rounded,
                            title: 'Nothing saved yet',
                            message: 'Tap the bookmark on any post — workouts, recipes, blogs — to keep it here.',
                          ),
                        ])
                      : GridView.builder(
                          controller: _scroll,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(16),
                          itemCount: _posts.length,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 3, crossAxisSpacing: 3),
                          itemBuilder: (_, i) => ClipRRect(borderRadius: BorderRadius.circular(6), child: PostGridTile(post: _posts[i])),
                        ),
                ),
    );
  }
}

/// My unpublished drafts.
class DraftsScreen extends StatefulWidget {
  const DraftsScreen({super.key});

  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  late Future<List<FeedPost>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<Session>().api.feedDrafts();
  }

  Future<void> _reload() async {
    final f = context.read<Session>().api.feedDrafts();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {}
  }

  Future<void> _delete(FeedPost p) async {
    try {
      await context.read<Session>().api.deleteFeedPost(p.id);
      if (!mounted) return;
      toast(context, 'Draft deleted');
      _reload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Drafts')),
      body: AsyncBody<List<FeedPost>>(
        future: _future,
        onRetry: _reload,
        builder: (context, drafts) {
          if (drafts.isEmpty) {
            return const EmptyView(
              icon: Icons.drafts_outlined,
              title: 'No drafts',
              message: 'Tap “Save draft” while creating a post to finish it later.',
            );
          }
          return RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _reload,
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: drafts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final p = drafts[i];
                final (label, icon, color) = switch (p.kind) {
                  'blog' => ('Blog', Icons.article_rounded, AppColors.blue),
                  'journey' => ('Journey', Icons.compare_rounded, AppColors.purple),
                  _ => ('Photo post', Icons.photo_library_rounded, AppColors.primary),
                };
                final title = (p.title?.isNotEmpty ?? false)
                    ? p.title!
                    : (p.caption?.isNotEmpty ?? false)
                        ? p.caption!
                        : 'Untitled ${label.toLowerCase()}';
                return AppCard(
                  padding: const EdgeInsets.all(12),
                  onTap: () async {
                    await push<FeedPost>(context, ComposePostScreen(kind: p.kind, existing: p));
                    if (mounted) _reload();
                  },
                  child: Row(children: [
                    SizedBox(
                      width: 64,
                      height: 64,
                      child: p.thumbnail == null
                          ? IconBubble(icon, color: color, size: 64)
                          : NetImage(p.thumbnail, fallback: categoryLook(p.category).image, radius: 14),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Tag(label, icon: icon, color: color, dense: true),
                        const SizedBox(height: 6),
                        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text('Started ${formatShortDate(p.createdAt)}', style: const TextStyle(fontSize: 12, color: AppColors.text3)),
                      ]),
                    ),
                    IconButton(
                      onPressed: () => _delete(p),
                      icon: const Icon(Icons.delete_outline_rounded, color: AppColors.text3),
                    ),
                  ]),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
