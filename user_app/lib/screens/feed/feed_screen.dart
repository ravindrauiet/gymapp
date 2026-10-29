import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/feed_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'compose_screen.dart';
import 'feed_lists_screen.dart';
import 'feed_profile_screen.dart';
import 'feed_widgets.dart';
import 'post_menu.dart';

/// FitFeed — photo posts, expert blogs and transformation journeys (BRD §1). Pushed from the Home grid.
class FitFeedScreen extends StatefulWidget {
  const FitFeedScreen({super.key});

  @override
  State<FitFeedScreen> createState() => _FitFeedScreenState();
}

class _FitFeedScreenState extends State<FitFeedScreen> {
  @override
  Widget build(BuildContext context) {
    final me = context.watch<Session>().user;
    return DefaultTabController(
      length: FeedTab.values.length,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          titleSpacing: 4,
          title: const Row(children: [
            Text('FitFeed', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22, letterSpacing: -0.6)),
            SizedBox(width: 6),
            Icon(Icons.local_fire_department_rounded, color: AppColors.primary, size: 22),
          ]),
          actions: [
            IconButton(
              tooltip: 'Saved',
              onPressed: () => push(context, const SavedPostsScreen()),
              icon: const Icon(Icons.bookmark_border_rounded),
            ),
            if (me != null)
              Padding(
                padding: const EdgeInsets.only(right: 10, left: 2),
                child: Tap(
                  onTap: () => push(context, FeedProfileScreen(userId: me.id)),
                  child: PersonAvatar(name: me.name, size: 32),
                ),
              ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: AppColors.text,
            unselectedLabelColor: AppColors.text3,
            indicatorColor: AppColors.primary,
            indicatorWeight: 3,
            indicatorSize: TabBarIndicatorSize.label,
            dividerColor: AppColors.line,
            labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, fontFamily: kFont),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, fontFamily: kFont),
            tabs: [for (final t in FeedTab.values) Tab(text: t.label)],
          ),
        ),
        body: TabBarView(children: [for (final t in FeedTab.values) _FeedList(tab: t)]),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'fitfeed-create',
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          onPressed: () => openCreatePost(context),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Post', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }
}

/// "+" sheet: Photo, Blog or Journey (plus drafts).
Future<void> openCreatePost(BuildContext context) async {
  final kind = await showAppSheet<String>(context, builder: (ctx) {
    Widget option(String id, IconData icon, Color color, String title, String sub, String image) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Tap(
            onTap: () => Navigator.pop(ctx, id),
            child: Container(
              height: 84,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), color: AppColors.surface, border: Border.all(color: AppColors.line)),
              clipBehavior: Clip.antiAlias,
              child: Row(children: [
                SizedBox(width: 84, height: 84, child: Image.asset(image, fit: BoxFit.cover)),
                const SizedBox(width: 14),
                IconBubble(icon, color: color, size: 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                    const SizedBox(height: 2),
                    Text(sub, maxLines: 2, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.3)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
                const SizedBox(width: 8),
              ]),
            ),
          ),
        );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Create', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          const SizedBox(height: 14),
          option('photo', Icons.photo_library_rounded, AppColors.primary, 'Photo post', 'Workout pics, progress, tips — up to 10 photos',
              AppImages.gym),
          option('blog', Icons.article_rounded, AppColors.blue, 'Blog', 'Form tips, diet plans, recipes — with a cover & images',
              AppImages.foodBowl),
          option('journey', Icons.compare_rounded, AppColors.purple, 'Journey', 'Before / after with your stats and a timeline',
              AppImages.running),
          TextButton.icon(
            onPressed: () => Navigator.pop(ctx, 'drafts'),
            icon: const Icon(Icons.drafts_outlined),
            label: const Text('My drafts'),
          ),
        ]),
      ),
    );
  });
  if (kind == null || !context.mounted) return;
  if (kind == 'drafts') {
    await push(context, const DraftsScreen());
  } else {
    await push<FeedPost>(context, ComposePostScreen(kind: kind));
  }
}

class _FeedList extends StatefulWidget {
  const _FeedList({required this.tab});
  final FeedTab tab;

  @override
  State<_FeedList> createState() => _FeedListState();
}

class _FeedListState extends State<_FeedList> with AutomaticKeepAliveClientMixin {
  final _posts = <FeedPost>[];
  final _scroll = ScrollController();
  String? _cursor;
  String? _category;
  bool _loading = true;
  bool _loadingMore = false;
  bool _done = false;
  Object? _error;
  Future<List<FeedPerson>>? _suggestions;
  StreamSubscription<FeedEvent>? _sub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 900) _loadMore();
    });
    _sub = FeedBus.stream.listen(_onEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onEvent(FeedEvent e) {
    if (!mounted) return;
    if (e is PostCreated) {
      final p = e.post;
      final fits = (_category == null || p.category == _category) &&
          switch (widget.tab) {
            FeedTab.forYou || FeedTab.following => true,
            FeedTab.journeys => p.kind == 'journey',
            FeedTab.experts => false,
          };
      if (fits && !_posts.any((x) => x.id == p.id)) setState(() => _posts.insert(0, p));
      return;
    }
    if (applyFeedEvent(_posts, e)) setState(() {});
    if (e is FollowChanged && widget.tab == FeedTab.following) _refresh();
  }

  Future<void> _load() async {
    final api = context.read<Session>().api;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await api.feed(tab: widget.tab, category: _category);
      if (!mounted) return;
      setState(() {
        _posts
          ..clear()
          ..addAll(page.posts);
        _cursor = page.nextCursor;
        _done = page.nextCursor == null;
        _loading = false;
        if (widget.tab == FeedTab.following && _posts.isEmpty) _suggestions = api.feedSuggestions();
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

  Future<void> _refresh() async {
    final api = context.read<Session>().api;
    try {
      final page = await api.feed(tab: widget.tab, category: _category);
      if (!mounted) return;
      setState(() {
        _posts
          ..clear()
          ..addAll(page.posts);
        _cursor = page.nextCursor;
        _done = page.nextCursor == null;
        _error = null;
        if (widget.tab == FeedTab.following && _posts.isEmpty) _suggestions = api.feedSuggestions();
      });
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _done || _cursor == null) return;
    final api = context.read<Session>().api;
    setState(() => _loadingMore = true);
    try {
      final page = await api.feed(tab: widget.tab, category: _category, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        final seen = _posts.map((p) => p.id).toSet();
        _posts.addAll(page.posts.where((p) => !seen.contains(p.id)));
        _cursor = page.nextCursor;
        _done = page.nextCursor == null;
        _loadingMore = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingMore = false);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  void _setCategory(String? c) {
    if (c == _category) return;
    _category = c;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final chips = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 12),
        child: ChoiceChips<String?>(
          options: [null, ...feedCategories.keys],
          selected: _category,
          onSelected: _setCategory,
          label: (c) => c == null ? 'All' : feedCategories[c]!,
          icon: (c) => c == null ? Icons.apps_rounded : categoryLook(c).icon,
        ),
      ),
    );

    final List<Widget> content;
    if (_loading) {
      content = [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.list(children: const [PostSkeleton(), PostSkeleton()]),
        ),
      ];
    } else if (_error != null) {
      content = [SliverFillRemaining(hasScrollBody: false, child: ErrorView(error: _error!, onRetry: _load))];
    } else if (_posts.isEmpty) {
      content = [SliverToBoxAdapter(child: _empty())];
    } else {
      content = [
        if (widget.tab == FeedTab.forYou && _category == null) const SliverToBoxAdapter(child: _CreatePrompt()),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.builder(
            itemCount: _posts.length,
            itemBuilder: (_, i) => PostCard(
              key: ValueKey(_posts[i].id),
              post: _posts[i],
              onMenu: (p) => showPostMenu(context, p),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
            child: _loadingMore
                ? const PostSkeleton()
                : _done
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Center(
                          child: Text("You're all caught up 🎉", style: TextStyle(color: AppColors.text3, fontWeight: FontWeight.w700)),
                        ),
                      )
                    : const SizedBox(height: 40),
          ),
        ),
      ];
    }

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _refresh,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [chips, ...content],
      ),
    );
  }

  Widget _empty() {
    final cat = _category == null ? '' : ' in ${feedCategories[_category]}';
    switch (widget.tab) {
      case FeedTab.following:
        return Column(children: [
          const EmptyView(
            icon: Icons.group_add_rounded,
            title: 'Follow people you love',
            message: 'Posts from trainers, nutritionists and members you follow show up here.',
          ),
          if (_suggestions != null) _Suggestions(future: _suggestions!),
          const SizedBox(height: 100),
        ]);
      case FeedTab.journeys:
        return EmptyView(
          icon: Icons.compare_rounded,
          color: AppColors.purple,
          title: 'No journeys$cat yet',
          message: 'Share your before / after and inspire someone today.',
          action: SizedBox(
            width: 210,
            child: AppButton(
              label: 'Share my journey',
              icon: Icons.add_rounded,
              color: AppColors.purple,
              onPressed: () => push<FeedPost>(context, const ComposePostScreen(kind: 'journey')),
            ),
          ),
        );
      case FeedTab.experts:
        return EmptyView(
          icon: Icons.article_rounded,
          color: AppColors.blue,
          title: 'No expert blogs$cat yet',
          message: 'Verified trainers and nutritionists will publish form tips, diet plans and recipes here.',
        );
      case FeedTab.forYou:
        return EmptyView(
          icon: Icons.dynamic_feed_rounded,
          title: 'Nothing here$cat yet',
          message: 'Be the first to post — a workout photo, a tip or your journey.',
          action: SizedBox(
            width: 180,
            child: AppButton(label: 'Create post', icon: Icons.add_rounded, onPressed: () => openCreatePost(context)),
          ),
        );
    }
  }
}

class _CreatePrompt extends StatelessWidget {
  const _CreatePrompt();

  @override
  Widget build(BuildContext context) {
    final me = context.watch<Session>().user;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        onTap: () => openCreatePost(context),
        child: Row(children: [
          PersonAvatar(name: me?.name, size: 38),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Share a workout, tip or journey…', style: TextStyle(color: AppColors.text3, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            onPressed: () => push<FeedPost>(context, const ComposePostScreen(kind: 'photo')),
            icon: const Icon(Icons.photo_library_outlined, color: AppColors.primary),
          ),
        ]),
      ),
    );
  }
}

class _Suggestions extends StatefulWidget {
  const _Suggestions({required this.future});
  final Future<List<FeedPerson>> future;
  @override
  State<_Suggestions> createState() => _SuggestionsState();
}

class _SuggestionsState extends State<_Suggestions> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<FeedPerson>>(
      future: widget.future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 3, itemHeight: 52);
        final people = snap.data ?? const <FeedPerson>[];
        if (people.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SectionTitle('Suggested for you', padding: EdgeInsets.only(bottom: 12)),
            for (final p in people)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: PersonRow(person: p, onChanged: () => setState(() {})),
              ),
          ]),
        );
      },
    );
  }
}

/// A person with a follow button — used by suggestions and follower lists.
class PersonRow extends StatelessWidget {
  const PersonRow({super.key, required this.person, this.onChanged});
  final FeedPerson person;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final sub = [
      if (p.city != null) p.city!,
      if (p.followers != null) '${compactCount(p.followers!)} followers',
    ].join(' · ');
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      onTap: () => push(context, FeedProfileScreen(userId: p.id)),
      child: Row(children: [
        PersonAvatar(name: p.displayName, photoUrl: p.avatarUrl, size: 46),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
            if (p.badge != null) ...[const SizedBox(height: 3), FeedBadgeTag(p.badge)],
            if (sub.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(sub, style: const TextStyle(fontSize: 12, color: AppColors.text3)),
            ],
          ]),
        ),
        if (!p.isMe)
          SizedBox(
            height: 36,
            child: p.following
                ? OutlinedButton(
                    onPressed: () async {
                      p.following = false;
                      onChanged?.call();
                      p.following = await FeedActions.setFollow(context, p.id, false);
                      onChanged?.call();
                    },
                    child: const Text('Following'),
                  )
                : FilledButton(
                    onPressed: () async {
                      p.following = true;
                      onChanged?.call();
                      p.following = await FeedActions.setFollow(context, p.id, true);
                      onChanged?.call();
                    },
                    child: const Text('Follow'),
                  ),
          ),
      ]),
    );
  }
}
