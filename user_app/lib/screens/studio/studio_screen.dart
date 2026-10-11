import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import 'video_player_screen.dart';

/// U5 — FitKey Studio: trainer videos by category.
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  late Future<(List<VideoCategoryCount>, List<Video>)> _future = _load();

  Future<(List<VideoCategoryCount>, List<Video>)> _load() async {
    final api = context.read<Session>().api;
    final r = await Future.wait([api.videoCategories(), api.videos(limit: 6)]);
    return (r[0] as List<VideoCategoryCount>, r[1] as List<Video>);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FitKey Studio')),
      body: AsyncView<(List<VideoCategoryCount>, List<Video>)>(
        future: _future,
        onRetry: () => setState(() => _future = _load()),
        builder: (context, data) {
          final (categories, latest) = data;
          return RefreshIndicator(
            onRefresh: () async {
              setState(() => _future = _load());
              await _future;
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: [
                const Text('Train with FITKEY coaches, anywhere.', style: TextStyle(color: FkColors.textSecondary)),
                const SizedBox(height: 16),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.25,
                  children: categories.map((c) => _CategoryTile(category: c)).toList(),
                ),
                if (latest.isNotEmpty) ...[
                  const SectionHeader('Latest videos'),
                  ...latest.map((v) => Padding(padding: const EdgeInsets.only(bottom: 12), child: VideoTile(video: v))),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category});

  final VideoCategoryCount category;

  @override
  Widget build(BuildContext context) {
    final style = videoCategory(category.id);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VideoListScreen(category: category))),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            colors: [style.color.withValues(alpha: 0.28), style.color.withValues(alpha: 0.08)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: style.color.withValues(alpha: 0.3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(style.icon, color: style.color, size: 30),
          const Spacer(),
          Text(category.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          Text('${category.count} videos', style: const TextStyle(color: FkColors.textSecondary, fontSize: 12)),
        ]),
      ),
    );
  }
}

class VideoListScreen extends StatelessWidget {
  const VideoListScreen({super.key, required this.category});

  final VideoCategoryCount category;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(category.label)),
      body: AsyncView<List<Video>>(
        future: context.read<Session>().api.videos(category: category.id),
        builder: (context, videos) => videos.isEmpty
            ? const EmptyState(icon: Icons.video_library_outlined, title: 'Videos coming soon')
            : ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: videos.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, i) => VideoTile(video: videos[i]),
              ),
      ),
    );
  }
}

class VideoTile extends StatelessWidget {
  const VideoTile({super.key, required this.video});

  final Video video;

  @override
  Widget build(BuildContext context) {
    final style = videoCategory(video.category);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(video: video))),
        child: Row(children: [
          Container(
            width: 110,
            height: 84,
            decoration: BoxDecoration(
              color: style.color.withValues(alpha: 0.15),
              image: video.thumbnailUrl == null
                  ? null
                  : DecorationImage(image: NetworkImage(resolveMediaUrl(video.thumbnailUrl)!), fit: BoxFit.cover),
            ),
            child: const Center(child: Icon(Icons.play_circle_fill, size: 36, color: Colors.white)),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(video.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  [video.trainerName, formatDuration(video.durationSeconds), _levelLabel(video.level)]
                      .whereType<String>()
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  style: const TextStyle(color: FkColors.textSecondary, fontSize: 12),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  String _levelLabel(String level) => level[0].toUpperCase() + level.substring(1);
}
