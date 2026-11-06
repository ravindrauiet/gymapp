import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart' show resolveMediaUrl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../data/models.dart';
import '../../data/studio_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'studio_screen.dart';

class VideoPlayerScreen extends StatelessWidget {
  const VideoPlayerScreen({super.key, required this.video});

  final Video video;

  /// YouTube videos play in the official YouTube embedded player; uploads / direct URLs in video_player.
  @override
  Widget build(BuildContext context) => video.isYoutube ? _YoutubeVideoScreen(video: video) : _NativeVideoScreen(video: video);
}

class _NativeVideoScreen extends StatefulWidget {
  const _NativeVideoScreen({required this.video});

  final Video video;

  @override
  State<_NativeVideoScreen> createState() => _VideoPlayerScreenState();
}

class _YoutubeVideoScreen extends StatefulWidget {
  const _YoutubeVideoScreen({required this.video});

  final Video video;

  @override
  State<_YoutubeVideoScreen> createState() => _YoutubePlayerState();
}

class _VideoPlayerScreenState extends State<_NativeVideoScreen> {
  VideoPlayerController? _controller;
  bool _failed = false;
  bool _controls = true;
  bool _fullscreen = false;
  Timer? _hideTimer;
  late final Future<List<Video>> _related;

  @override
  void initState() {
    super.initState();
    _init();
    _related = _relatedFor(context, widget.video);
  }

  void _init() {
    final old = _controller;
    _controller = null;
    old?.removeListener(_onTick);
    old?.dispose();

    final url = resolveMediaUrl(widget.video.videoUrl);
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      _failed = true;
      return;
    }
    final c = VideoPlayerController.networkUrl(uri)..addListener(_onTick);
    _controller = c;
    _failed = false;
    c.initialize().then((_) {
      if (!mounted || _controller != c) return;
      c.play();
      _scheduleHide();
      setState(() {});
    }).catchError((Object _) {
      if (mounted && _controller == c) setState(() => _failed = true);
    });
  }

  void _onTick() {
    if (!mounted) return;
    final v = _controller?.value;
    if (v != null && v.hasError && !_failed) {
      setState(() => _failed = true);
      return;
    }
    setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) setState(() => _controls = false);
    });
  }

  void _toggleControls() {
    setState(() => _controls = !_controls);
    if (_controls) _scheduleHide();
  }

  bool _ended(VideoPlayerValue v) =>
      v.isInitialized &&
      !v.isPlaying &&
      v.duration > Duration.zero &&
      v.position >= v.duration - const Duration(milliseconds: 400);

  void _playPause() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    HapticFeedback.selectionClick();
    final v = c.value;
    if (v.isPlaying) {
      c.pause();
      _hideTimer?.cancel();
      setState(() => _controls = true);
    } else {
      if (_ended(v)) c.seekTo(Duration.zero);
      c.play();
      _scheduleHide();
    }
  }

  void _seekBy(int seconds) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final v = c.value;
    var target = v.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > v.duration) target = v.duration;
    c.seekTo(target);
    _scheduleHide();
  }

  Future<void> _setFullscreen(bool on) async {
    setState(() => _fullscreen = on);
    if (on) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(const []);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    if (_fullscreen) {
      SystemChrome.setPreferredOrientations(const []);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  static String _clock(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) _setFullscreen(false);
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: _fullscreen ? Colors.black : AppColors.bg,
          body: _fullscreen
              ? Center(child: _player(fullscreen: true))
              : Column(children: [
                  Container(
                    color: Colors.black,
                    padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
                    child: _player(fullscreen: false),
                  ),
                  Expanded(child: _details()),
                ]),
        ),
      ),
    );
  }

  Widget _player({required bool fullscreen}) {
    final c = _controller;
    final v = c?.value;
    final ready = !_failed && c != null && v != null && v.isInitialized;
    final ratio = ready && v.aspectRatio > 0 ? v.aspectRatio : 16 / 9;
    final fallback = studioVideoVisual(widget.video).image;

    Widget content;
    if (_failed) {
      content = Stack(fit: StackFit.expand, children: [
        NetImage(widget.video.thumbnailUrl, fallback: fallback),
        Container(color: Colors.black.withValues(alpha: 0.72)),
        Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.videocam_off_rounded, color: Colors.white, size: 36),
            const SizedBox(height: 10),
            const Text('This video could not be played',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15.5)),
            const SizedBox(height: 4),
            Text('Check your connection and try again.',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12.5)),
            const SizedBox(height: 14),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 42),
                backgroundColor: Colors.white,
                foregroundColor: AppColors.ink,
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
              onPressed: () => setState(_init),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again', style: TextStyle(fontSize: 14)),
            ),
          ]),
        ),
        _backButton(fullscreen),
      ]);
    } else if (!ready) {
      content = Stack(fit: StackFit.expand, children: [
        NetImage(widget.video.thumbnailUrl, fallback: fallback),
        Container(color: Colors.black.withValues(alpha: 0.5)),
        const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.6)),
        _backButton(fullscreen),
      ]);
    } else {
      final ended = _ended(v);
      content = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        onDoubleTapDown: (d) {
          final w = context.size?.width ?? 0;
          _seekBy(d.localPosition.dx < w / 2 ? -10 : 10);
        },
        onDoubleTap: () {},
        child: Stack(fit: StackFit.expand, children: [
          Center(child: AspectRatio(aspectRatio: ratio, child: VideoPlayer(c))),
          if (v.isBuffering && v.isPlaying)
            const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.6)),
          AnimatedOpacity(
            opacity: _controls || !v.isPlaying ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: IgnorePointer(
              ignoring: !(_controls || !v.isPlaying),
              child: _controlsOverlay(c, v, ended, fullscreen),
            ),
          ),
        ]),
      );
    }

    return fullscreen
        ? AspectRatio(aspectRatio: ratio, child: content)
        : AspectRatio(aspectRatio: 16 / 9, child: ColoredBox(color: Colors.black, child: content));
  }

  Widget _backButton(bool fullscreen) => Positioned(
        top: 4,
        left: 4,
        child: IconButton(
          tooltip: fullscreen ? 'Exit full screen' : 'Back',
          icon: Icon(fullscreen ? Icons.fullscreen_exit_rounded : Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => fullscreen ? _setFullscreen(false) : Navigator.maybePop(context),
        ),
      );

  Widget _controlsOverlay(VideoPlayerController c, VideoPlayerValue v, bool ended, bool fullscreen) {
    Widget round(IconData icon, VoidCallback onTap, {double size = 30, double box = 48, String? tip}) => Tooltip(
          message: tip ?? '',
          child: Tap(
            onTap: onTap,
            child: Container(
              width: box,
              height: box,
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), shape: BoxShape.circle),
              child: Icon(icon, color: Colors.white, size: size),
            ),
          ),
        );

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.55),
            Colors.black.withValues(alpha: 0.15),
            Colors.black.withValues(alpha: 0.65),
          ],
        ),
      ),
      child: Stack(children: [
        Positioned(
          top: 4,
          left: 4,
          right: 12,
          child: Row(children: [
            IconButton(
              tooltip: fullscreen ? 'Exit full screen' : 'Back',
              icon: Icon(fullscreen ? Icons.fullscreen_exit_rounded : Icons.arrow_back_rounded, color: Colors.white),
              onPressed: () => fullscreen ? _setFullscreen(false) : Navigator.maybePop(context),
            ),
            if (fullscreen)
              Expanded(
                child: Text(widget.video.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
              ),
          ]),
        ),
        Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            round(Icons.replay_10_rounded, () => _seekBy(-10), size: 26, box: 44, tip: 'Back 10 seconds'),
            const SizedBox(width: 26),
            round(
              ended ? Icons.replay_rounded : (v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
              _playPause,
              size: 40,
              box: 64,
              tip: v.isPlaying ? 'Pause' : 'Play',
            ),
            const SizedBox(width: 26),
            round(Icons.forward_10_rounded, () => _seekBy(10), size: 26, box: 44, tip: 'Forward 10 seconds'),
          ]),
        ),
        Positioned(
          left: 12,
          right: 4,
          bottom: 2,
          child: Row(children: [
            Text(_clock(v.position),
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(
              child: VideoProgressIndicator(
                c,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 14),
                colors: VideoProgressColors(
                  playedColor: AppColors.primary,
                  bufferedColor: Colors.white.withValues(alpha: 0.45),
                  backgroundColor: Colors.white.withValues(alpha: 0.2),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(_clock(v.duration),
                style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w700)),
            IconButton(
              tooltip: fullscreen ? 'Exit full screen' : 'Full screen',
              icon: Icon(fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, color: Colors.white),
              onPressed: () => _setFullscreen(!fullscreen),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _details() => _VideoDetails(video: widget.video, related: _related);
}

/// Other videos of the same Studio group (or legacy category).
Future<List<Video>> _relatedFor(BuildContext context, Video video) {
  final api = context.read<Session>().api;
  final group = video.groupKey;
  return (group != null ? api.studioVideos(group: group, limit: 12) : api.videos(category: video.category, limit: 12))
      .then((list) => list.where((v) => v.id != video.id).toList());
}

// ---------------------------------------------------------------------------
// YouTube videos — official YouTube IFrame player (youtube_player_iframe), Android + web.
// The video is streamed by YouTube; nothing is downloaded or re-hosted.
// ---------------------------------------------------------------------------

class _YoutubePlayerState extends State<_YoutubeVideoScreen> {
  late final YoutubePlayerController _yt;
  late final Future<List<Video>> _related;
  StreamSubscription<YoutubePlayerValue>? _sub;
  YoutubeError _error = YoutubeError.none;

  @override
  void initState() {
    super.initState();
    _yt = YoutubePlayerController.fromVideoId(
      videoId: widget.video.youtubeId!,
      autoPlay: true,
      params: const YoutubePlayerParams(
        showFullscreenButton: true,
        strictRelatedVideos: true,
        showVideoAnnotations: false,
      ),
    );
    _sub = _yt.stream.listen((v) {
      if (mounted && v.error != _error) setState(() => _error = v.error);
    });
    _related = _relatedFor(context, widget.video);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _yt.close();
    super.dispose();
  }

  Future<void> _openOnYoutube() async {
    final ok = await launchUrl(Uri.parse('https://www.youtube.com/watch?v=${widget.video.youtubeId}'),
            mode: LaunchMode.externalApplication)
        .catchError((_) => false);
    if (!ok && mounted) toast(context, 'Could not open YouTube', error: true);
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _error != YoutubeError.none;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: Column(children: [
          Container(
            color: Colors.black,
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            child: Column(children: [
              SizedBox(
                height: 44,
                child: Row(children: [
                  IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  Expanded(
                    child: Text(widget.video.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                  ),
                  IconButton(
                    tooltip: 'Open in YouTube',
                    icon: const Icon(Icons.open_in_new_rounded, color: Colors.white, size: 20),
                    onPressed: _openOnYoutube,
                  ),
                ]),
              ),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: blocked ? _blockedView() : YoutubePlayer(controller: _yt, backgroundColor: Colors.black),
              ),
            ]),
          ),
          Expanded(child: _VideoDetails(video: widget.video, related: _related)),
        ]),
      ),
    );
  }

  Widget _blockedView() {
    final notFound = _error == YoutubeError.videoNotFound || _error == YoutubeError.cannotFindVideo;
    final noEmbed = _error == YoutubeError.notEmbeddable ||
        _error == YoutubeError.sameAsNotEmbeddable ||
        _error == YoutubeError.sameAsNotEmbeddable2;
    final message = notFound
        ? 'This video was removed or made private on YouTube.'
        : noEmbed
            ? 'The owner only allows this video to be watched on YouTube.'
            : 'YouTube could not play this video right now.';
    return Stack(fit: StackFit.expand, children: [
      NetImage(widget.video.thumbnailUrl, fallback: studioVideoVisual(widget.video).image),
      Container(color: Colors.black.withValues(alpha: 0.75)),
      Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.videocam_off_rounded, color: Colors.white, size: 32),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
            if (!notFound) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.ink,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                onPressed: _openOnYoutube,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Watch on YouTube', style: TextStyle(fontSize: 14)),
              ),
            ],
          ]),
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Details below the player (shared by both players)
// ---------------------------------------------------------------------------

class _VideoDetails extends StatelessWidget {
  const _VideoDetails({required this.video, required this.related});

  final Video video;
  final Future<List<Video>> related;

  Future<void> _openChannel(BuildContext context) async {
    final url = video.channelUrl;
    if (url == null) return;
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!ok && context.mounted) toast(context, 'Could not open the channel', error: true);
  }

  @override
  Widget build(BuildContext context) {
    final visual = studioVideoVisual(video);
    final duration = studioDurationText(video.durationSeconds);
    final level = studioLevelLabel(video.level);
    final channel = video.channelName;
    final trainer = video.trainerName;
    // A real trainer is set when it differs from the channel name (the server falls back to the channel).
    final hasTrainer = trainer != null && trainer.isNotEmpty && trainer.toLowerCase() != channel?.toLowerCase();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
      children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          Tag(visual.label, icon: visual.icon, color: visual.color),
          if (level.isNotEmpty) Tag(level, icon: Icons.signal_cellular_alt_rounded, color: AppColors.text2),
          if (duration.isNotEmpty) Tag(duration, icon: Icons.schedule_rounded, color: AppColors.text2),
          if (video.equipment != null)
            Tag(studioEquipmentLabel(video.equipment!), icon: Icons.fitness_center_rounded, color: AppColors.text2),
        ]),
        const SizedBox(height: 12),
        Text(video.title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.2)),
        const SizedBox(height: 16),
        if (hasTrainer || channel == null)
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              PersonAvatar(name: trainer ?? 'FITKEY Coach', size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('YOUR COACH',
                      style: TextStyle(fontSize: 11, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: AppColors.text3)),
                  const SizedBox(height: 2),
                  Text(trainer ?? 'FITKEY Coach', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                ]),
              ),
              const IconBubble(Icons.verified_rounded, color: AppColors.blue, size: 36),
            ]),
          ),
        if (hasTrainer && channel != null) const SizedBox(height: 10),
        if (channel != null)
          Tap(
            onTap: video.channelUrl == null ? null : () => _openChannel(context),
            child: AppCard(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                PersonAvatar(name: channel, size: 46),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('VIDEO BY',
                        style: TextStyle(fontSize: 11, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: AppColors.text3)),
                    const SizedBox(height: 2),
                    Text(channel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                    const SizedBox(height: 2),
                    Text(
                        video.playlistTitle != null
                            ? 'YouTube channel · from "${video.playlistTitle}"'
                            : 'YouTube channel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: AppColors.text2)),
                  ]),
                ),
                if (video.channelUrl != null)
                  const IconBubble(Icons.smart_display_rounded, color: AppColors.red, size: 36),
              ]),
            ),
          ),
        if (video.description != null && video.description!.isNotEmpty) ...[
          const SectionTitle('About this class', padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
          Text(video.description!, style: const TextStyle(height: 1.55, color: AppColors.text2, fontSize: 14.5)),
        ],
        FutureBuilder<List<Video>>(
          future: related,
          builder: (context, snap) {
            final list = snap.data;
            if (list == null || list.isEmpty) return const SizedBox.shrink();
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SectionTitle('More ${visual.label} classes'),
              SizedBox(
                height: 228,
                child: OverflowBox(
                  maxWidth: MediaQuery.sizeOf(context).width,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (_, i) => SizedBox(width: 230, child: VideoTile(video: list[i])),
                  ),
                ),
              ),
            ]);
          },
        ),
      ],
    );
  }
}
