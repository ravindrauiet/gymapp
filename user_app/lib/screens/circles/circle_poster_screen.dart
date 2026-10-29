import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams, XFile;

import '../../data/circles_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'circles_common.dart';

/// Leader-only printable QR poster. The payload is a signed, non-expiring circle token
/// (replace the poster to invalidate old prints).
class CirclePosterScreen extends StatefulWidget {
  const CirclePosterScreen({super.key, required this.circle});
  final CircleSummary circle;

  @override
  State<CirclePosterScreen> createState() => _CirclePosterScreenState();
}

class _CirclePosterScreenState extends State<CirclePosterScreen> {
  final _posterKey = GlobalKey();
  late Future<({String qr, int version})> _future = context.read<Session>().api.circleQr(widget.circle.id);
  bool _sharing = false;

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      final boundary = _posterKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('no bytes');
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(bytes.buffer.asUint8List(), mimeType: 'image/png', name: 'circle-qr-poster.png')],
        fileNameOverrides: ['circle-qr-poster.png'],
        text: widget.circle.name,
      ));
    } catch (_) {
      if (mounted) toast(context, CirclesPrefs.instance.t('shareFailed'), error: true);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _rotate() async {
    final p = CirclesPrefs.instance;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.t('newPoster')),
        content: Text(p.t('newPosterConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(p.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(p.t('confirm'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _future = context.read<Session>().api.circleQr(widget.circle.id, rotate: true));
  }

  @override
  Widget build(BuildContext context) {
    return CirclesShell(child: Builder(builder: (context) {
      final p = circlesOf(context);
      final c = widget.circle;
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(title: Text(p.t('qrPoster')), actions: [
          IconButton(onPressed: _rotate, tooltip: p.t('newPoster'), icon: const Icon(Icons.autorenew_rounded)),
        ]),
        bottomNavigationBar: BottomActionBar(
          child: AppButton(label: p.t('sharePoster'), icon: Icons.ios_share_rounded, busy: _sharing, onPressed: _share),
        ),
        body: FutureBuilder<({String qr, int version})>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(24), child: SkeletonBox(height: 520, radius: 24));
            }
            if (snap.hasError) {
              return ErrorView(
                error: snap.error!,
                onRetry: () => setState(() => _future = context.read<Session>().api.circleQr(c.id)),
              );
            }
            final v = circleVisual(c.activity);
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: RepaintBoundary(
                  key: _posterKey,
                  // Poster is rendered with fixed text size so the printout looks the same for everyone.
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
                    child: Container(
                      width: 340,
                      padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: AppShadows.card,
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          IconBubble(v.icon, color: v.color, size: 36),
                          const SizedBox(width: 8),
                          const Text('FITKEY CIRCLES',
                              style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, color: AppColors.primary)),
                        ]),
                        const SizedBox(height: 14),
                        Text(c.name,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, height: 1.15, color: AppColors.ink)),
                        const SizedBox(height: 6),
                        Text(c.placeName,
                            textAlign: TextAlign.center, style: const TextStyle(color: AppColors.text2, fontSize: 14)),
                        Text(scheduleLine(p, c),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w700, fontSize: 14)),
                        const SizedBox(height: 18),
                        QrImageView(
                          data: snap.data!.qr,
                          version: QrVersions.auto,
                          size: 250,
                          backgroundColor: Colors.white,
                          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: AppColors.ink),
                          dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: AppColors.ink),
                        ),
                        const SizedBox(height: 14),
                        Text(p.t('posterTitle'),
                            textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(p.t('posterFoot'),
                            textAlign: TextAlign.center, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                        if (c.inviteCode != null) ...[
                          const SizedBox(height: 12),
                          Tag('${p.t('inviteCode')}: ${c.inviteCode}', icon: Icons.key_rounded),
                        ],
                      ]),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }));
  }
}
