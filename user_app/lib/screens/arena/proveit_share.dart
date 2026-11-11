import 'dart:ui' as ui;

import 'package:fitkey_core/fitkey_core.dart' show formatDate;
import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams, XFile;

import '../../data/feed_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../../widgets/brand.dart';
import 'arena_visuals.dart';

/// What a ProveIt share card shows: an achievement (badge), a finished set, or my AIR / city rank.
class ProveItShareData {
  const ProveItShareData({
    required this.exerciseId,
    required this.exerciseName,
    required this.headline,
    required this.value,
    required this.unit,
    this.lines = const [],
    this.caption,
  });

  final String exerciseId;
  final String exerciseName;

  /// e.g. "Level 2 complete", "All India Rank", "Unlimited set".
  final String headline;

  /// The big number, e.g. "50", "#12", "62".
  final String value;

  /// Under the number, e.g. "reps", "seconds", "in India".
  final String unit;

  /// Small facts, e.g. ["AIR #12", "Delhi #3"].
  final List<String> lines;

  /// Default text for the post / share message.
  final String? caption;
}

/// Opens the share screen for [data].
Future<void> shareProveIt(BuildContext context, ProveItShareData data) =>
    push(context, ProveItShareScreen(data: data));

enum _Format { story, post }

/// Preview of the branded card + Post to FitFeed / share to WhatsApp, Instagram and other apps.
class ProveItShareScreen extends StatefulWidget {
  const ProveItShareScreen({super.key, required this.data});
  final ProveItShareData data;

  @override
  State<ProveItShareScreen> createState() => _ProveItShareScreenState();
}

class _ProveItShareScreenState extends State<ProveItShareScreen> {
  final _cardKey = GlobalKey();
  _Format _format = _Format.story;
  bool _sharing = false;
  bool _posting = false;
  bool _posted = false;

  Size get _cardSize => _format == _Format.story ? const Size(360, 640) : const Size(360, 450);

  String get _caption =>
      widget.data.caption ??
      '${widget.data.headline} — ${widget.data.exerciseName}: ${widget.data.value} ${widget.data.unit}. '
          'Only real reps count. #ProveIt #FITKEY';

  /// Renders the card to PNG (1080 px wide). Falls back to a smaller render if the file would be over 3 MB.
  Future<Uint8List> _png() async {
    final boundary = _cardKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    for (final ratio in [3.0, 2.0, 1.5]) {
      final image = await boundary.toImage(pixelRatio: ratio * _cardSize.width / boundary.size.width);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) continue;
      final out = bytes.buffer.asUint8List();
      if (out.length < 2900 * 1024) return out;
    }
    throw StateError('The card could not be rendered');
  }

  String get _fileName => 'proveit-${widget.data.exerciseId}-${DateTime.now().millisecondsSinceEpoch}.png';

  Future<void> _shareToApps() async {
    setState(() => _sharing = true);
    try {
      final bytes = await _png();
      final name = _fileName;
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(bytes, mimeType: 'image/png', name: name)],
        fileNameOverrides: [name],
        text: _caption,
      ));
    } catch (e) {
      if (mounted) {
        toast(
            context,
            kIsWeb
                ? 'This browser cannot share images. Post it to FitFeed, or share from the FITKEY app.'
                : 'Could not open the share sheet. Please try again.',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _postToFeed() async {
    final controller = TextEditingController(text: _caption);
    final caption = await showAppSheet<String>(
      context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Post to FitFeed', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(height: 4),
          const Text('Your card is posted publicly as a photo post.',
              style: TextStyle(color: AppColors.text2, fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLines: 4,
            maxLength: 2200,
            decoration: const InputDecoration(hintText: 'Say something about your set'),
          ),
          const SizedBox(height: 8),
          AppButton(label: 'Post', icon: Icons.send_rounded, onPressed: () => Navigator.pop(ctx, controller.text.trim())),
        ]),
      ),
    );
    controller.dispose();
    if (caption == null || !mounted) return;
    final api = context.read<Session>().api;
    setState(() => _posting = true);
    try {
      final bytes = await _png();
      final url = await api.upload(XFile.fromData(bytes, mimeType: 'image/png', name: _fileName));
      await api.createFeedPost({
        'kind': 'photo',
        'images': [url],
        'caption': caption.isEmpty ? null : caption,
        'category': 'gym',
        'visibility': 'public',
      });
      if (!mounted) return;
      setState(() => _posted = true);
      toast(context, 'Posted to FitFeed', icon: Icons.check_circle_rounded);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = context.watch<Session>().user?.name;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Share')),
      body: Column(children: [
        const SizedBox(height: 12),
        ChoiceChips<_Format>(
          options: _Format.values,
          selected: _format,
          label: (f) => f == _Format.story ? 'Story 9:16' : 'Post 4:5',
          icon: (f) => f == _Format.story ? Icons.crop_portrait_rounded : Icons.crop_square_rounded,
          onSelected: (f) => setState(() => _format = f),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: FittedBox(
                child: RepaintBoundary(
                  key: _cardKey,
                  child: SizedBox.fromSize(
                    size: _cardSize,
                    child: ProveItCard(data: widget.data, userName: name, compact: _format == _Format.post),
                  ),
                ),
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'In the share sheet pick WhatsApp, Instagram (Story or Post) or any app.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.text2, fontSize: 12.5),
          ),
        ),
      ]),
      bottomNavigationBar: BottomActionBar(
        child: Row(children: [
          Expanded(
            flex: 5,
            child: SizedBox(
              height: 54,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10)),
                onPressed: _posting || _posted ? null : _postToFeed,
                icon: _posting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(_posted ? Icons.check_rounded : Icons.dynamic_feed_rounded),
                label: FittedBox(child: Text(_posted ? 'Posted' : 'FitFeed', maxLines: 1, softWrap: false)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 7,
            child: AppButton(label: 'Share to apps', icon: Icons.ios_share_rounded, busy: _sharing, onPressed: _shareToApps),
          ),
        ]),
      ),
    );
  }
}

/// The branded ProveIt card (fixed logical size; rendered to PNG by [ProveItShareScreen]).
class ProveItCard extends StatelessWidget {
  const ProveItCard({super.key, required this.data, this.userName, this.compact = false});
  final ProveItShareData data;
  final String? userName;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final v = arenaVisual(data.exerciseId);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1B25), Color(0xFF2A1E2B), Color(0xFF3B1D17)],
        ),
      ),
      child: Stack(children: [
        Positioned(
          right: -90,
          top: compact ? -60 : 40,
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [AppColors.primary.withValues(alpha: 0.55), Colors.transparent]),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(24, compact ? 22 : 34, 24, compact ? 20 : 30),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const BrandLockup(size: 26, light: true),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: AppColors.lime, borderRadius: BorderRadius.circular(20)),
                child: const Text('PROVEIT',
                    style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1.4)),
              ),
            ]),
            const Spacer(),
            Container(
              width: compact ? 48 : 60,
              height: compact ? 48 : 60,
              decoration: BoxDecoration(color: v.color, borderRadius: BorderRadius.circular(18)),
              child: Icon(v.icon, color: Colors.white, size: compact ? 26 : 32),
            ),
            SizedBox(height: compact ? 12 : 18),
            Text(data.headline.toUpperCase(),
                style: const TextStyle(color: AppColors.lime, fontWeight: FontWeight.w800, fontSize: 13, letterSpacing: 1.6)),
            const SizedBox(height: 4),
            Text(data.exerciseName,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 26, letterSpacing: -0.5)),
            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Text(data.value,
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: compact ? 76 : 96,
                      height: 1.05,
                      letterSpacing: -3)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(data.unit,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontWeight: FontWeight.w700, fontSize: 20)),
              ),
            ]),
            if (data.lines.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final l in data.lines)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(l, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
              ]),
            ],
            const Spacer(),
            Text(userName?.trim().isNotEmpty == true ? userName! : 'A FITKEY member',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
            Text(formatDate(DateTime.now()),
                style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12.5)),
            SizedBox(height: compact ? 10 : 16),
            Row(children: [
              const Icon(Icons.verified_rounded, color: AppColors.lime, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Only real reps count · counted by AI on FITKEY',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
