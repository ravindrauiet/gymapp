import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';

class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.video});

  final Video video;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final VideoPlayerController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.video.videoUrl))
      ..addListener(() {
        if (mounted) setState(() {});
      });
    _controller.initialize().then((_) => _controller.play()).catchError((Object _) {
      if (mounted) setState(() => _error = 'This video could not be loaded.');
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _clock(Duration d) =>
      '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final value = _controller.value;
    return Scaffold(
      appBar: AppBar(title: Text(videoCategory(video.category).label)),
      body: ListView(
        children: [
          AspectRatio(
            aspectRatio: value.isInitialized ? value.aspectRatio : 16 / 9,
            child: Container(
              color: Colors.black,
              child: _error != null
                  ? ErrorState(message: _error!)
                  : !value.isInitialized
                      ? const Center(child: CircularProgressIndicator())
                      : GestureDetector(
                          onTap: () => value.isPlaying ? _controller.pause() : _controller.play(),
                          child: Stack(alignment: Alignment.center, children: [
                            VideoPlayer(_controller),
                            if (!value.isPlaying)
                              const CircleAvatar(
                                radius: 32,
                                backgroundColor: Colors.black54,
                                child: Icon(Icons.play_arrow, size: 40, color: Colors.white),
                              ),
                            if (value.isBuffering) const CircularProgressIndicator(),
                          ]),
                        ),
            ),
          ),
          if (value.isInitialized)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                IconButton(
                  icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
                  onPressed: () => value.isPlaying ? _controller.pause() : _controller.play(),
                ),
                Expanded(
                  child: VideoProgressIndicator(
                    _controller,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    colors: const VideoProgressColors(
                      playedColor: FkColors.lime,
                      bufferedColor: FkColors.outline,
                      backgroundColor: FkColors.surfaceHigh,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text('${_clock(value.position)} / ${_clock(value.duration)}',
                    style: const TextStyle(fontSize: 12, color: FkColors.textSecondary)),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(video.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Row(children: [
                Avatar(name: video.trainerName, radius: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(video.trainerName ?? 'FITKEY Trainer', style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (video.durationSeconds != null)
                  Text(formatDuration(video.durationSeconds), style: const TextStyle(color: FkColors.textSecondary)),
              ]),
              if (video.description != null) ...[
                const SizedBox(height: 16),
                Text(video.description!, style: const TextStyle(height: 1.5, color: FkColors.textSecondary)),
              ],
            ]),
          ),
        ],
      ),
    );
  }
}
