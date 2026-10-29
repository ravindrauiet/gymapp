import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart' show formatDate, formatShortDate;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/feed_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../trainers/trainer_detail_screen.dart';
import 'compose_screen.dart';
import 'feed_widgets.dart';
import 'post_menu.dart';

/// A FitFeed post: photo carousel, blog reader view or journey (before/after + timeline), with comments.
class PostDetailScreen extends StatefulWidget {
  const PostDetailScreen({super.key, required this.postId});
  final String postId;

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  FeedPost? _post;
  Object? _error;
  final _comments = <FeedComment>[];
  String? _commentCursor;
  bool _commentsLoading = true;
  bool _moreLoading = false;
  final _input = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;
  StreamSubscription<FeedEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = FeedBus.stream.listen((e) {
      final p = _post;
      if (p == null || !mounted) return;
      if (e is PostEdited && e.post.id == p.id) {
        _load();
      } else if (e is FollowChanged && e.userId == p.author.id) {
        setState(() => p.author.following = e.following);
      } else if (e is PostChanged && e.post.id == p.id && !identical(e.post, p)) {
        if (applyFeedEvent([p], e)) setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<Session>().api;
    setState(() => _error = null);
    try {
      final post = await api.feedPost(widget.postId);
      if (!mounted) return;
      setState(() => _post = post);
      if (!post.isDraft) _loadComments(reset: true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadComments({bool reset = false}) async {
    final api = context.read<Session>().api;
    if (reset) setState(() => _commentsLoading = true);
    try {
      final r = await api.feedComments(widget.postId, cursor: reset ? null : _commentCursor);
      if (!mounted) return;
      setState(() {
        if (reset) _comments.clear();
        _comments.addAll(r.comments);
        _commentCursor = r.nextCursor;
        _commentsLoading = false;
        _moreLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _commentsLoading = false;
          _moreLoading = false;
        });
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final post = _post;
    if (text.isEmpty || post == null) return;
    final api = context.read<Session>().api;
    setState(() => _sending = true);
    try {
      final c = await api.addFeedComment(post.id, text);
      if (!mounted) return;
      _input.clear();
      setState(() {
        _comments.insert(0, c);
        post.commentCount++;
        _sending = false;
      });
      FeedBus.emit(PostChanged(post));
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  Future<void> _deleteComment(FeedComment c) async {
    final post = _post!;
    final api = context.read<Session>().api;
    final i = _comments.indexOf(c);
    setState(() {
      _comments.remove(c);
      post.commentCount = (post.commentCount - 1).clamp(0, 1 << 31);
    });
    try {
      await api.deleteFeedComment(c.id);
      FeedBus.emit(PostChanged(post));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _comments.insert(i.clamp(0, _comments.length), c);
        post.commentCount++;
      });
      toast(context, friendlyError(e), error: true);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _menu() async {
    final post = _post;
    if (post == null) return;
    final deleted = await showPostMenu(context, post);
    if (deleted && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final post = _post;
    if (post == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Post')),
        body: _error != null
            ? ErrorView(error: _error!, onRetry: _load)
            : const SingleChildScrollView(padding: EdgeInsets.all(16), child: PostSkeleton()),
      );
    }
    final blog = post.kind == 'blog';
    return Scaffold(
      backgroundColor: blog ? AppColors.surface : AppColors.bg,
      appBar: blog
          ? null
          : AppBar(
              title: Text(post.kind == 'journey' ? 'Journey' : 'Post'),
              actions: [
                if (!post.isDraft)
                  IconButton(onPressed: () => FeedActions.share(context, post, _refresh), icon: const Icon(Icons.ios_share_rounded)),
                IconButton(onPressed: _menu, icon: const Icon(Icons.more_vert_rounded)),
              ],
            ),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: CustomScrollView(slivers: [
          if (blog) ..._blogHeader(post) else SliverToBoxAdapter(child: _mediaCard(post)),
          if (post.isDraft)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AppCard(
                  color: AppColors.amberSoft,
                  shadow: false,
                  child: Row(children: [
                    const Icon(Icons.drafts_rounded, color: AppColors.amber),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('This is a draft — only you can see it.', style: TextStyle(fontWeight: FontWeight.w700))),
                    TextButton(
                      onPressed: () => push<FeedPost>(context, ComposePostScreen(kind: post.kind, existing: post)),
                      child: const Text('Edit'),
                    ),
                  ]),
                ),
              ),
            ),
          if (post.author.trainerId != null && !post.isMine) SliverToBoxAdapter(child: _ExpertCta(post: post)),
          if (post.kind == 'journey') SliverToBoxAdapter(child: _Timeline(post: post, onChanged: _load)),
          if (!post.isDraft) ..._commentSlivers(post),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ]),
      ),
      bottomNavigationBar: post.isDraft ? null : _composer(),
    );
  }

  Widget _mediaCard(FeedPost post) {
    void like() => FeedActions.toggleLike(context, post, _refresh, onlyLike: true);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(22), boxShadow: AppShadows.card),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PostHeader(post: post),
        if (post.kind == 'journey')
          BeforeAfterSlider(beforeUrl: post.journey?.beforeUrl, afterUrl: post.journey?.afterUrl, onDoubleTap: like)
        else
          PhotoCarousel(images: post.images, onDoubleTap: like, fallback: categoryLook(post.category).image),
        if (post.kind == 'journey' && post.journey != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: JourneyStatsRow(journey: post.journey!),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              Tag(post.journey!.goalLabel, icon: Icons.flag_rounded, color: AppColors.purple),
              if (post.journey!.start.date != null) Tag('Since ${_date(post.journey!.start.date!)}', color: AppColors.text2),
              if (post.facesBlurred) const Tag('Faces blurred', icon: Icons.blur_on_rounded, color: AppColors.teal),
            ]),
          ),
        ],
        const SizedBox(height: 4),
        PostActionsBar(post: post, refresh: _refresh, onComment: () => _focus.requestFocus()),
        PostCaption(post: post, expanded: true),
        const SizedBox(height: 14),
      ]),
    );
  }

  List<Widget> _blogHeader(FeedPost post) {
    final a = post.author;
    final look = categoryLook(post.category);
    return [
      SliverAppBar(
        pinned: true,
        expandedHeight: 280,
        backgroundColor: AppColors.surface,
        actions: [
          if (!post.isDraft)
            IconButton(onPressed: () => FeedActions.share(context, post, _refresh), icon: const Icon(Icons.ios_share_rounded)),
          IconButton(onPressed: _menu, icon: const Icon(Icons.more_vert_rounded)),
        ],
        flexibleSpace: FlexibleSpaceBar(
          collapseMode: CollapseMode.parallax,
          background: Stack(fit: StackFit.expand, children: [
            NetImage(post.coverUrl, fallback: look.image),
            const PhotoScrim(strength: 0.25, from: Alignment.bottomCenter),
          ]),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, children: [
              if (post.category != null) Tag(feedCategories[post.category]!.toUpperCase(), icon: look.icon, color: look.color),
              Tag('${post.readMinutes ?? 1} MIN READ', color: AppColors.text2),
            ]),
            const SizedBox(height: 12),
            Text(post.title ?? 'Untitled',
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, height: 1.18, letterSpacing: -0.8)),
            const SizedBox(height: 16),
            PersonTap(
              userId: a.id,
              child: Row(children: [
                PersonAvatar(name: a.displayName, photoUrl: a.avatarUrl, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.displayName, style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Row(children: [
                      if (a.badge != null) ...[FeedBadgeTag(a.badge), const SizedBox(width: 6)],
                      Text(formatDate(post.time), style: const TextStyle(fontSize: 12, color: AppColors.text3)),
                    ]),
                  ]),
                ),
                if (!post.isMine)
                  SizedBox(
                    height: 36,
                    child: a.following
                        ? OutlinedButton(onPressed: () => FeedActions.setFollow(context, a.id, false), child: const Text('Following'))
                        : FilledButton(onPressed: () => FeedActions.setFollow(context, a.id, true), child: const Text('Follow')),
                  ),
              ]),
            ),
            const Padding(padding: EdgeInsets.symmetric(vertical: 18), child: Divider(height: 1, color: AppColors.line)),
            BlogBody(post.body ?? ''),
            const SizedBox(height: 8),
            const Divider(height: 1, color: AppColors.line),
          ]),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
          child: PostActionsBar(post: post, refresh: _refresh, onComment: () => _focus.requestFocus()),
        ),
      ),
    ];
  }

  List<Widget> _commentSlivers(FeedPost post) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
          child: Text(post.commentCount == 0 ? 'Comments' : 'Comments · ${post.commentCount}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        ),
      ),
      if (_commentsLoading)
        const SliverToBoxAdapter(child: SkeletonList(count: 2, itemHeight: 40))
      else if (_comments.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('No comments yet — start the conversation.', style: TextStyle(color: AppColors.text3)),
          ),
        )
      else ...[
        SliverList.builder(itemCount: _comments.length, itemBuilder: (_, i) => _commentTile(_comments[i])),
        if (_commentCursor != null)
          SliverToBoxAdapter(
            child: Center(
              child: _moreLoading
                  ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(
                      onPressed: () {
                        setState(() => _moreLoading = true);
                        _loadComments();
                      },
                      child: const Text('Load more comments'),
                    ),
            ),
          ),
      ],
    ];
  }

  Widget _commentTile(FeedComment c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PersonTap(userId: c.userId, child: PersonAvatar(name: c.userName, photoUrl: c.userAvatarUrl, size: 34)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(c.userName ?? 'FITKEY member',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              ),
              if (c.userBadge == 'trainer' || c.userBadge == 'nutritionist') ...[
                const SizedBox(width: 3),
                FeedBadgeTag(c.userBadge, iconOnly: true),
              ],
              const SizedBox(width: 6),
              Text(timeAgo(c.createdAt), style: const TextStyle(fontSize: 12, color: AppColors.text3)),
            ]),
            const SizedBox(height: 2),
            Text(c.body, style: const TextStyle(fontSize: 14, height: 1.4)),
          ]),
        ),
        if (c.canDelete)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Delete comment',
            onPressed: () => _deleteComment(c),
            icon: const Icon(Icons.delete_outline_rounded, size: 19, color: AppColors.text3),
          ),
      ]),
    );
  }

  Widget _composer() {
    final me = context.watch<Session>().user;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        boxShadow: [BoxShadow(color: Color(0x141A1B25), blurRadius: 20, offset: Offset(0, -4))],
      ),
      padding: EdgeInsets.fromLTRB(12, 8, 8, 8 + MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Row(children: [
          PersonAvatar(name: me?.name, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              minLines: 1,
              maxLines: 4,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Add a comment…',
                counterText: '',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 4),
          _sending
              ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(onPressed: _send, icon: const Icon(Icons.send_rounded, color: AppColors.primary)),
        ]),
      ),
    );
  }
}

String _date(String ymd) {
  final d = DateTime.tryParse(ymd);
  return d == null ? ymd : formatShortDate(d);
}

/// Trainer authors link to their Trainers booking page.
class _ExpertCta extends StatelessWidget {
  const _ExpertCta({required this.post});
  final FeedPost post;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: AppCard(
        onTap: () => push(context, TrainerDetailScreen(trainerId: post.author.trainerId!)),
        child: Row(children: [
          const IconBubble(Icons.sports_rounded, color: AppColors.blue),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Train with ${post.author.displayName.split(' ').first}', style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              const Text('Verified FITKEY trainer · book a 1:1 session', style: TextStyle(color: AppColors.text2, fontSize: 12.5)),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
        ]),
      ),
    );
  }
}

/// Journey timeline + "Add update" for the author.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.post, required this.onChanged});
  final FeedPost post;
  final Future<void> Function() onChanged;

  Future<void> _add(BuildContext context) async {
    final added = await showAppSheet<bool>(context, builder: (_) => _AddUpdateSheet(postId: post.id));
    if (added == true) await onChanged();
  }

  Future<void> _remove(BuildContext context, JourneyUpdate u) async {
    try {
      await context.read<Session>().api.deleteJourneyUpdate(post.id, u.id);
      await onChanged();
    } catch (e) {
      if (context.mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final updates = post.updates ?? const <JourneyUpdate>[];
    final j = post.journey;
    final entries = <({DateTime? at, String title, String? note, String? photo, double? weight, JourneyUpdate? update})>[
      if (j != null)
        (
          at: j.start.date == null ? null : DateTime.tryParse(j.start.date!),
          title: 'Day 1',
          note: 'Started the ${j.goalLabel.toLowerCase()} journey',
          photo: null,
          weight: j.start.weightKg,
          update: null,
        ),
      for (final u in updates) (at: u.createdAt, title: 'Update', note: u.note, photo: u.photoUrl, weight: u.weightKg, update: u),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionTitle('Timeline',
            subtitle: '${updates.length} ${updates.length == 1 ? 'update' : 'updates'}',
            action: post.isMine ? 'Add update' : null,
            onAction: () => _add(context),
            padding: const EdgeInsets.fromLTRB(0, 22, 0, 12)),
        AppCard(
          padding: const EdgeInsets.fromLTRB(14, 14, 8, 6),
          child: Column(children: [
            for (var i = 0; i < entries.length; i++)
              IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Column(children: [
                    Container(
                      width: 14,
                      height: 14,
                      margin: const EdgeInsets.only(top: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == entries.length - 1 ? AppColors.purple : AppColors.purpleSoft,
                        border: Border.all(color: AppColors.purple, width: 2),
                      ),
                    ),
                    if (i != entries.length - 1) Expanded(child: Container(width: 2, color: AppColors.purpleSoft)),
                  ]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Text(entries[i].title, style: const TextStyle(fontWeight: FontWeight.w800)),
                          if (entries[i].at != null) ...[
                            const SizedBox(width: 8),
                            Text(formatShortDate(entries[i].at!), style: const TextStyle(color: AppColors.text3, fontSize: 12)),
                          ],
                          const Spacer(),
                          if (entries[i].weight != null) Tag(kg(entries[i].weight!), color: AppColors.purple, dense: true),
                          if (post.isMine && entries[i].update != null)
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _remove(context, entries[i].update!),
                              icon: const Icon(Icons.close_rounded, size: 17, color: AppColors.text3),
                            ),
                        ]),
                        if ((entries[i].note ?? '').isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(entries[i].note!, style: const TextStyle(color: AppColors.text2, height: 1.4)),
                        ],
                        if (entries[i].photo != null) ...[
                          const SizedBox(height: 8),
                          NetImage(entries[i].photo, fallback: AppImages.gymFloor, height: 160, radius: 14),
                        ],
                      ]),
                    ),
                  ),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _AddUpdateSheet extends StatefulWidget {
  const _AddUpdateSheet({required this.postId});
  final String postId;
  @override
  State<_AddUpdateSheet> createState() => _AddUpdateSheetState();
}

class _AddUpdateSheetState extends State<_AddUpdateSheet> {
  final _note = TextEditingController();
  final _weight = TextEditingController();
  XFile? _photo;
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    _weight.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
    if (f != null && mounted) setState(() => _photo = f);
  }

  Future<void> _save() async {
    final weight = double.tryParse(_weight.text.trim().replaceAll(',', '.'));
    final note = _note.text.trim();
    if (note.isEmpty && weight == null && _photo == null) {
      toast(context, 'Add a note, a photo or your weight', error: true);
      return;
    }
    final api = context.read<Session>().api;
    setState(() => _busy = true);
    try {
      final url = _photo == null ? null : await api.upload(_photo!);
      await api.addJourneyUpdate(widget.postId, note: note.isEmpty ? null : note, photoUrl: url, weightKg: weight);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Journey update', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          TextField(
            controller: _note,
            maxLines: 3,
            maxLength: 1000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'How is it going? e.g. “Week 8 — first pull-up!”'),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _weight,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Weight today', suffixText: 'kg'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pick,
                icon: Icon(_photo == null ? Icons.add_a_photo_outlined : Icons.check_circle_rounded),
                label: Text(_photo == null ? 'Add photo' : 'Photo added'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          AppButton(label: 'Post update', icon: Icons.check_rounded, busy: _busy, onPressed: _save),
        ]),
      ),
    );
  }
}
