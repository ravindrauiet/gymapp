import 'package:fitkey_core/fitkey_core.dart' show formatDuration;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'video_player_screen.dart';

String _levelLabel(String level) => level.isEmpty ? level : level[0].toUpperCase() + level.substring(1);

Color _levelColor(String level) => switch (level) {
      'beginner' => AppColors.green,
      'intermediate' => AppColors.amber,
      'advanced' => AppColors.red,
      _ => AppColors.blue,
    };

typedef _StudioData = (List<VideoCategoryCount>, List<Video>);

/// U5 — FitKey Studio: trainer videos by category. A bottom-nav tab inside HomeShell.
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  late Future<_StudioData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_StudioData> _load() async {
    final api = context.read<Session>().api;
    final r = await Future.wait([api.videoCategories(), api.videos(limit: 30)]);
    return (r[0] as List<VideoCategoryCount>, r[1] as List<Video>);
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* shown by the FutureBuilder */}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: [
            const _Header(),
            FutureBuilder<_StudioData>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const _StudioSkeleton();
                if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
                final (categories, videos) = snap.data!;
                if (categories.isEmpty && videos.isEmpty) {
                  return const EmptyView(
                    icon: Icons.video_library_rounded,
                    title: 'No videos yet',
                    message: 'FITKEY coaches add new classes every week. Pull down to refresh.',
                  );
                }
                return _Feed(categories: categories, videos: videos);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 14, 16, 16),
      child: const Row(children: [
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
    );
  }
}

class _Feed extends StatelessWidget {
  const _Feed({required this.categories, required this.videos});
  final List<VideoCategoryCount> categories;
  final List<Video> videos;

  @override
  Widget build(BuildContext context) {
    final hero = videos.isEmpty ? null : videos.first;
    final byCategory = <String, List<Video>>{};
    for (final v in videos) {
      byCategory.putIfAbsent(v.category, () => []).add(v);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (hero != null)
          PhotoBanner(
            image: videoVisual(hero.category).image,
            eyebrow: 'New in studio · ${videoVisual(hero.category).label}',
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
        if (categories.isNotEmpty) ...[
          const SectionTitle('Browse by category', subtitle: 'Pick your vibe for today'),
          SizedBox(
            height: 150,
            child: OverflowBox(
              maxWidth: MediaQuery.sizeOf(context).width,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: categories.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, i) => _CategoryCard(category: categories[i]),
              ),
            ),
          ),
        ],
        if (videos.isNotEmpty) ...[
          const SectionTitle('Latest classes', subtitle: 'Fresh from FITKEY coaches'),
          _VideoRail(videos: videos.take(8).toList()),
        ],
        for (final c in categories)
          if ((byCategory[c.id] ?? const []).isNotEmpty) ...[
            SectionTitle(
              c.label,
              subtitle: '${c.count} video${c.count == 1 ? '' : 's'}',
              action: 'See all',
              onAction: () => push(context, VideoListScreen(category: c)),
            ),
            _VideoRail(videos: byCategory[c.id]!),
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

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.category});
  final VideoCategoryCount category;

  @override
  Widget build(BuildContext context) {
    final v = videoVisual(category.id);
    return Tap(
      onTap: () => push(context, VideoListScreen(category: category)),
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
              Text(category.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800, height: 1.15)),
              const SizedBox(height: 2),
              Text('${category.count} video${category.count == 1 ? '' : 's'}',
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
    final visual = videoVisual(v.category);
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
          Text('  ·  ${visual.label}',
              maxLines: 1, style: TextStyle(fontSize: 12.5, color: visual.color, fontWeight: FontWeight.w700)),
        ]),
      ]),
    );
  }
}
