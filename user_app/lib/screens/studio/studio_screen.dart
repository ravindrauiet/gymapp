import 'package:fitkey_core/fitkey_core.dart' show formatDuration;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/studio_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'search_widgets.dart';
import 'studio_group_screen.dart';
import 'video_player_screen.dart';

String _levelLabel(String level) => studioLevelLabel(level);

Color _levelColor(String level) => switch (level) {
      'beginner' => AppColors.green,
      'intermediate' => AppColors.amber,
      'advanced' => AppColors.red,
      _ => AppColors.blue,
    };

typedef _StudioData = (List<StudioGroup>, List<Video>);

const _recentStore = RecentSearches('fitkey_recent_studio_search');

/// U5 — FitKey Studio: search + category groups (BRD §5, §7). A bottom-nav tab inside HomeShell.
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  late Future<_StudioData> _future;
  final _search = TextEditingController();
  final _debounce = Debouncer();
  List<StudioGroup> _groups = const [];
  List<String> _recents = const [];

  /// The query the current results are for ('' = not searching).
  String _query = '';
  Future<List<Video>>? _results;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _recentStore.load().then((r) {
      if (mounted) setState(() => _recents = r);
    });
  }

  @override
  void dispose() {
    _debounce.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<_StudioData> _load() async {
    final api = context.read<Session>().api;
    final r = await Future.wait([api.studioGroups(), api.videos(limit: 30)]);
    final groups = r[0] as List<StudioGroup>;
    if (mounted) _groups = groups;
    return (groups, r[1] as List<Video>);
  }

  Future<void> _reload() async {
    if (_query.isNotEmpty) {
      _runSearch(_query);
      try {
        await _results;
      } catch (_) {/* shown by the FutureBuilder */}
      return;
    }
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* shown by the FutureBuilder */}
  }

  void _onChanged(String text) {
    final q = text.trim();
    if (q.isEmpty) {
      _debounce.cancel();
      setState(() {
        _query = '';
        _results = null;
      });
      return;
    }
    setState(() {}); // hide recent searches while typing
    _debounce(() {
      if (mounted && q != _query) _runSearch(q);
    });
  }

  void _runSearch(String q) {
    setState(() {
      _query = q;
      _results = context.read<Session>().api.studioVideos(q: q, limit: 40);
    });
  }

  Future<void> _remember(String q) async {
    final next = await _recentStore.add(q);
    if (mounted) setState(() => _recents = next);
  }

  void _onSubmitted(String text) {
    final q = text.trim();
    if (q.isEmpty) return;
    _debounce.cancel();
    _runSearch(q);
    _remember(q);
  }

  void _useRecent(String q) {
    _search.text = q;
    _search.selection = TextSelection.collapsed(offset: q.length);
    _onSubmitted(q);
  }

  Future<void> _clearRecents() async {
    await _recentStore.clear();
    if (mounted) setState(() => _recents = const []);
  }

  void _openGroup(StudioGroup g) => push(context, StudioGroupScreen(group: g));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.zero,
          children: [
            _Header(
              controller: _search,
              onChanged: _onChanged,
              onSubmitted: _onSubmitted,
              recents: _search.text.trim().isEmpty ? _recents : const [],
              onRecent: _useRecent,
              onClearRecents: _clearRecents,
            ),
            if (_query.isNotEmpty && _results != null)
              _SearchResults(
                query: _query,
                future: _results!,
                groups: _groups,
                onRetry: () => _runSearch(_query),
                onOpenVideo: (v) {
                  _remember(_query);
                  push(context, VideoPlayerScreen(video: v));
                },
                onOpenGroup: _openGroup,
              )
            else
              FutureBuilder<_StudioData>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) return const _StudioSkeleton();
                  if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
                  final (groups, videos) = snap.data!;
                  if (groups.isEmpty && videos.isEmpty) {
                    return const EmptyView(
                      icon: Icons.video_library_rounded,
                      title: 'No videos yet',
                      message: 'FITKEY coaches add new classes every week. Pull down to refresh.',
                    );
                  }
                  return _Feed(groups: groups, videos: videos, onOpenGroup: _openGroup);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    required this.recents,
    required this.onRecent,
    required this.onClearRecents,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final List<String> recents;
  final ValueChanged<String> onRecent;
  final VoidCallback onClearRecents;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 14, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Studio', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.9, height: 1.1)),
              SizedBox(height: 4),
              Text('Train with FITKEY coaches, anywhere',
                  style: TextStyle(fontSize: 13, color: AppColors.text2, fontWeight: FontWeight.w500)),
            ]),
          ),
          SizedBox(width: 12),
          IconBubble(Icons.play_circle_fill_rounded, color: AppColors.primary, size: 46),
        ]),
        const SizedBox(height: 14),
        RotatingSearchBar(
          hints: const ['yoga classes', 'HIIT workouts', 'Zumba', 'abs & core', 'boxing basics', 'by trainer name'],
          controller: controller,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
        RecentSearchRow(recents: recents, onTap: onRecent, onClear: onClearRecents),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Search results
// ---------------------------------------------------------------------------

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.query,
    required this.future,
    required this.groups,
    required this.onRetry,
    required this.onOpenVideo,
    required this.onOpenGroup,
  });

  final String query;
  final Future<List<Video>> future;
  final List<StudioGroup> groups;
  final VoidCallback onRetry;
  final ValueChanged<Video> onOpenVideo;
  final ValueChanged<StudioGroup> onOpenGroup;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Video>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SkeletonList(count: 4, itemHeight: 84);
        }
        if (snap.hasError) return ErrorView(error: snap.error!, onRetry: onRetry);
        final videos = snap.data!;
        if (videos.isEmpty) {
          return EmptyView(
            icon: Icons.search_off_rounded,
            title: 'No results',
            message: groups.isEmpty
                ? 'Nothing matches "$query". Try a different word or a trainer\'s name.'
                : 'Nothing matches "$query". Try one of these categories:',
            action: groups.isEmpty
                ? null
                : SuggestionChips(
                    items: [for (final g in groups) g.key],
                    label: (k) => groups.firstWhere((g) => g.key == k).label,
                    icon: (k) => studioGroupVisual(k).icon,
                    onTap: (k) => onOpenGroup(groups.firstWhere((g) => g.key == k)),
                  ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SectionTitle('${videos.length} result${videos.length == 1 ? '' : 's'}', subtitle: 'for "$query"'),
            for (final v in videos)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _VideoRow(video: v, onTap: () => onOpenVideo(v)),
              ),
          ]),
        );
      },
    );
  }
}

/// Compact search-result row: thumbnail + title + trainer · group · duration.
class _VideoRow extends StatelessWidget {
  const _VideoRow({required this.video, required this.onTap});
  final Video video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = video;
    final visual = studioVideoVisual(v);
    final duration = formatDuration(v.durationSeconds);
    return Tap(
      onTap: onTap,
      child: AppCard(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          SizedBox(
            width: 116,
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(fit: StackFit.expand, children: [
                  NetImage(v.thumbnailUrl, fallback: visual.image),
                  const PhotoScrim(strength: 0.4),
                  const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 30)),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, height: 1.25)),
              const SizedBox(height: 4),
              Text(v.trainerName ?? 'FITKEY Coach',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                Tag(v.groupLabel ?? visual.label, color: visual.color, dense: true),
                Tag(_levelLabel(v.level), color: _levelColor(v.level), dense: true),
                if (duration.isNotEmpty) Tag(duration, color: AppColors.text2, bg: AppColors.surfaceAlt, dense: true),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Home feed
// ---------------------------------------------------------------------------

class _Feed extends StatelessWidget {
  const _Feed({required this.groups, required this.videos, required this.onOpenGroup});
  final List<StudioGroup> groups;
  final List<Video> videos;
  final ValueChanged<StudioGroup> onOpenGroup;

  @override
  Widget build(BuildContext context) {
    final hero = videos.isEmpty ? null : videos.first;
    final heroVisual = hero == null ? null : studioVideoVisual(hero);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (hero != null)
          PhotoBanner(
            image: heroVisual!.image,
            eyebrow: 'New in studio · ${hero.groupLabel ?? heroVisual.label}',
            // PhotoBanner does not clamp lines, so keep very long titles to ~2 lines.
            title: hero.title.length > 52 ? '${hero.title.substring(0, 50).trimRight()}…' : hero.title,
            subtitle: [hero.trainerName, formatDuration(hero.durationSeconds), _levelLabel(hero.level)]
                .whereType<String>()
                .where((s) => s.isNotEmpty)
                .join(' · '),
            cta: 'Play now',
            height: 200,
            onTap: () => push(context, VideoPlayerScreen(video: hero)),
          )
        else
          const PhotoBanner(
            image: AppImages.homeWorkout,
            eyebrow: 'FitKey studio',
            title: 'Your home workout, coached.',
            subtitle: 'Yoga, strength, dance & more from FITKEY trainers.',
            height: 180,
          ),
        if (groups.isNotEmpty) ...[
          const SectionTitle('Browse by category', subtitle: 'Pick your vibe for today'),
          SizedBox(
            height: 150,
            child: OverflowBox(
              maxWidth: MediaQuery.sizeOf(context).width,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: groups.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, i) => _GroupCard(group: groups[i], onTap: () => onOpenGroup(groups[i])),
              ),
            ),
          ),
        ],
        if (videos.isNotEmpty) ...[
          const SectionTitle('Latest classes', subtitle: 'Fresh from FITKEY coaches'),
          _VideoRail(videos: videos.take(8).toList()),
        ],
        for (final g in groups)
          if (videos.where((v) => v.groups.contains(g.key)).toList() case final inGroup when inGroup.isNotEmpty) ...[
            SectionTitle(
              g.label,
              subtitle: '${g.count} video${g.count == 1 ? '' : 's'}',
              action: 'See all',
              onAction: () => onOpenGroup(g),
            ),
            _VideoRail(videos: inGroup),
          ],
      ]),
    );
  }
}

class _VideoRail extends StatelessWidget {
  const _VideoRail({required this.videos});
  final List<Video> videos;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 228,
      child: OverflowBox(
        maxWidth: MediaQuery.sizeOf(context).width,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: videos.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (_, i) => SizedBox(width: 250, child: VideoTile(video: videos[i])),
        ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.onTap});
  final StudioGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = group.visual;
    return Tap(
      onTap: onTap,
      child: Container(
        width: 124,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), boxShadow: AppShadows.soft),
        clipBehavior: Clip.antiAlias,
        child: Stack(fit: StackFit.expand, children: [
          Image.asset(v.image, fit: BoxFit.cover),
          const PhotoScrim(strength: 0.85),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: v.color, borderRadius: BorderRadius.circular(10)),
                child: Icon(v.icon, color: Colors.white, size: 18),
              ),
              const Spacer(),
              Text(group.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800, height: 1.15)),
              const SizedBox(height: 2),
              Text('${group.count} video${group.count == 1 ? '' : 's'}',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _StudioSkeleton extends StatelessWidget {
  const _StudioSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SkeletonBox(height: 200, radius: 22),
          SizedBox(height: 28),
          SkeletonBox(height: 20, width: 180),
          SizedBox(height: 14),
          Row(children: [
            SkeletonBox(height: 150, width: 124, radius: 20),
            SizedBox(width: 12),
            SkeletonBox(height: 150, width: 124, radius: 20),
          ]),
          SizedBox(height: 28),
          SkeletonBox(height: 20, width: 160),
          SizedBox(height: 14),
          SkeletonBox(height: 140, width: 250, radius: 18),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Category list
// ---------------------------------------------------------------------------

class VideoListScreen extends StatefulWidget {
  const VideoListScreen({super.key, required this.category});

  final VideoCategoryCount category;

  @override
  State<VideoListScreen> createState() => _VideoListScreenState();
}

class _VideoListScreenState extends State<VideoListScreen> {
  late Future<List<Video>> _future;
  String _level = 'all';

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Video>> _load() => context.read<Session>().api.videos(category: widget.category.id);

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* shown by the FutureBuilder */}
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.category;
    final visual = videoVisual(c.id);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(c.label)),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _reload,
        child: FutureBuilder<List<Video>>(
          future: _future,
          builder: (context, snap) {
            final header = Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: PhotoBanner(
                image: visual.image,
                eyebrow: 'FitKey studio',
                title: '${c.label} classes',
                subtitle: '${c.count} video${c.count == 1 ? '' : 's'} by FITKEY coaches',
                height: 150,
              ),
            );
            if (snap.connectionState != ConnectionState.done) {
              return ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
                header,
                const Shimmer(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(children: [
                      SkeletonBox(height: 220, radius: 18),
                      SizedBox(height: 18),
                      SkeletonBox(height: 220, radius: 18),
                    ]),
                  ),
                ),
              ]);
            }
            if (snap.hasError) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [header, ErrorView(error: snap.error!, onRetry: _reload)],
              );
            }
            final all = snap.data!;
            if (all.isEmpty) {
              return ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
                header,
                EmptyView(
                  icon: visual.icon,
                  color: visual.color,
                  title: 'No ${c.label} videos yet',
                  message: 'Explore another category in the Studio meanwhile.',
                  action: SizedBox(
                    width: 200,
                    child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Back to Studio')),
                  ),
                ),
              ]);
            }
            const order = ['beginner', 'intermediate', 'advanced'];
            final levels = all.map((v) => v.level).toSet().toList()
              ..sort((a, b) {
                final ia = order.indexOf(a), ib = order.indexOf(b);
                return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
              });
            final level = levels.contains(_level) ? _level : 'all';
            final videos = level == 'all' ? all : all.where((v) => v.level == level).toList();
            final wide = MediaQuery.sizeOf(context).width >= 640;

            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                header,
                if (levels.length > 1) ...[
                  const SizedBox(height: 16),
                  ChoiceChips<String>(
                    options: ['all', ...levels],
                    selected: level,
                    label: (l) => l == 'all' ? 'All levels' : _levelLabel(l),
                    onSelected: (l) => setState(() => _level = l),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: wide
                      ? GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          itemCount: videos.length,
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2, mainAxisSpacing: 18, crossAxisSpacing: 14, childAspectRatio: 1.15),
                          itemBuilder: (_, i) => VideoTile(video: videos[i]),
                        )
                      : Column(children: [
                          for (final v in videos) Padding(padding: const EdgeInsets.only(bottom: 20), child: VideoTile(video: v)),
                        ]),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Video card
// ---------------------------------------------------------------------------

/// Thumbnail card: 16:9 photo with play button, duration badge and level tag, then title + trainer.
class VideoTile extends StatelessWidget {
  const VideoTile({super.key, required this.video});

  final Video video;

  @override
  Widget build(BuildContext context) {
    final v = video;
    final visual = studioVideoVisual(v);
    final duration = formatDuration(v.durationSeconds);
    return Tap(
      onTap: () => push(context, VideoPlayerScreen(video: v)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), boxShadow: AppShadows.card),
            clipBehavior: Clip.antiAlias,
            child: Stack(fit: StackFit.expand, children: [
              NetImage(v.thumbnailUrl, fallback: visual.image),
              const PhotoScrim(strength: 0.55),
              Center(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    shape: BoxShape.circle,
                    boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12)],
                  ),
                  child: const Icon(Icons.play_arrow_rounded, color: AppColors.ink, size: 30),
                ),
              ),
              Positioned(
                left: 10,
                top: 10,
                child: Tag(_levelLabel(v.level).toUpperCase(), color: _levelColor(v.level), solid: true, dense: true),
              ),
              if (duration.isNotEmpty)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.schedule_rounded, color: Colors.white, size: 12),
                      const SizedBox(width: 4),
                      Text(duration,
                          style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        Text(v.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, height: 1.25, letterSpacing: -0.2)),
        const SizedBox(height: 5),
        Row(children: [
          PersonAvatar(name: v.trainerName ?? 'FITKEY Coach', size: 20),
          const SizedBox(width: 6),
          Flexible(
            child: Text(v.trainerName ?? 'FITKEY Coach',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
          ),
          Text('  ·  ${v.groupLabel ?? visual.label}',
              maxLines: 1, style: TextStyle(fontSize: 12.5, color: visual.color, fontWeight: FontWeight.w700)),
        ]),
      ]),
    );
  }
}
