part of '../venue_editor_screen.dart';

// ---------------------------------------------------------------------------
// Step 5 — up to 10 photos (blur / size check, cover + reorder) + optional MP4 video tour
// ---------------------------------------------------------------------------
class _PhotosStep extends StatefulWidget {
  const _PhotosStep({
    required this.venue,
    required this.onChanged,
    required this.onUploading,
    required this.onVideoCleared,
    required this.onVideoSet,
  });

  final PartnerVenue venue;
  final VoidCallback onChanged;
  final ValueChanged<int> onUploading;
  final VoidCallback onVideoCleared;
  final VoidCallback onVideoSet;

  @override
  State<_PhotosStep> createState() => _PhotosStepState();
}

class _PhotosStepState extends State<_PhotosStep> {
  static const _maxPhotoBytes = 3 * 1024 * 1024;
  static const _maxVideoBytes = 50 * 1024 * 1024;

  final _picker = ImagePicker();

  /// Uploads in flight, keyed by a local id, with a preview of the picked bytes and the stage label.
  final _uploading = <int, ({Uint8List? preview, String stage})>{};
  int _nextId = 0;
  bool _videoUploading = false;

  int get _remaining => maxPhotos - widget.venue.photos.length - _uploading.length;

  void _report() => widget.onUploading(_uploading.length + (_videoUploading ? 1 : 0));

  Future<void> _add(ImageSource source) async {
    try {
      final List<XFile> files;
      // No maxWidth here: downscaling before the size check would hide too-small photos. imageQuality keeps
      // the upload light; very large files are rejected below with a friendly message.
      if (source == ImageSource.camera || _remaining == 1) {
        final f = await _picker.pickImage(source: source, maxWidth: 2400, imageQuality: 82);
        files = f == null ? [] : [f];
      } else {
        files = await _picker.pickMultiImage(maxWidth: 2400, imageQuality: 82, limit: _remaining);
      }
      if (!mounted) return;
      if (files.length > _remaining) {
        toast(context, 'Only $_remaining more photo${_remaining == 1 ? '' : 's'} can be added', icon: Icons.info_outline_rounded);
      }
      for (final f in files.take(_remaining)) {
        _upload(f);
      }
    } catch (_) {
      if (mounted) toast(context, 'Couldn\'t open photos. Check the app\'s permissions.', error: true);
    }
  }

  Future<void> _upload(XFile file) async {
    if (!mounted) return;
    final api = context.read<PartnerSession>().api;
    final id = _nextId++;
    setState(() => _uploading[id] = (preview: null, stage: 'Checking…'));
    _report();
    try {
      final bytes = await file.readAsBytes();
      if (mounted) setState(() => _uploading[id] = (preview: bytes, stage: 'Checking…'));
      final check = await compute(checkPhoto, bytes);
      if (!check.ok) throw _UserMessage(check.message ?? 'This photo can\'t be used');
      if (bytes.length > _maxPhotoBytes) throw const _UserMessage('Each photo must be under 3 MB');
      if (mounted) setState(() => _uploading[id] = (preview: bytes, stage: 'Uploading…'));
      final url = await api.upload(file);
      widget.venue.photos.add(url);
      widget.onChanged();
    } catch (e) {
      if (mounted) _showRejected(e is _UserMessage ? e.message : friendlyError(e));
    } finally {
      _uploading.remove(id);
      if (mounted) setState(() {});
      _report();
    }
  }

  void _showRejected(String message) {
    showAppSheet<void>(
      context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const IconBubble(Icons.hide_image_rounded, color: AppColors.amber, size: 56),
            const SizedBox(height: 12),
            const Text('Photo not added', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.text2, height: 1.4)),
            const SizedBox(height: 16),
            AppButton(
              label: 'Choose another photo',
              onPressed: () {
                Navigator.pop(ctx);
                _pickSource();
              },
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _addVideo() async {
    try {
      final f = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 2));
      if (f == null || !mounted) return;
      final name = f.name.toLowerCase();
      final mime = (f.mimeType ?? '').toLowerCase();
      if (!(name.endsWith('.mp4') || mime == 'video/mp4')) {
        toast(context, 'Please pick an MP4 video', error: true);
        return;
      }
      final size = await f.length();
      if (size > _maxVideoBytes) {
        if (mounted) toast(context, 'Keep the video under 50 MB (about 1 minute)', error: true);
        return;
      }
      if (!mounted) return;
      final api = context.read<PartnerSession>().api;
      setState(() => _videoUploading = true);
      _report();
      final url = await api.upload(f);
      widget.venue.videoUrl = url;
      widget.onVideoSet();
      widget.onChanged();
      if (mounted) toast(context, 'Video tour added', icon: Icons.movie_rounded);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _videoUploading = false);
      _report();
    }
  }

  void _pickSource() {
    if (_remaining <= 0) return;
    showAppSheet<void>(
      context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Add photos', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            _SheetOption(
              icon: Icons.photo_library_rounded,
              title: 'Choose from gallery',
              subtitle: 'Pick up to $_remaining',
              onTap: () {
                Navigator.pop(ctx);
                _add(ImageSource.gallery);
              },
            ),
            const SizedBox(height: 10),
            _SheetOption(
              icon: Icons.photo_camera_rounded,
              title: 'Take a photo',
              subtitle: 'Use the camera now',
              onTap: () {
                Navigator.pop(ctx);
                _add(ImageSource.camera);
              },
            ),
          ]),
        ),
      ),
    );
  }

  void _move(int from, int to) {
    final photos = widget.venue.photos;
    if (to < 0 || to >= photos.length) return;
    setState(() => photos.insert(to, photos.removeAt(from)));
    widget.onChanged();
  }

  void _remove(int i) {
    setState(() => widget.venue.photos.removeAt(i));
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.venue.photos;
    final count = photos.length;
    final enough = count >= minPhotosToSubmit;
    final fallback = venueVisual(widget.venue.categories.firstOrNull ?? '').image;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _StepIntro('Show off your space',
            'Add $minPhotosToSubmit–$maxPhotos bright, sharp photos: entrance, main floor, equipment, changing rooms. '
            'The first photo is your cover.'),
        AppCard(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            IconBubble(enough ? Icons.check_circle_rounded : Icons.photo_camera_back_rounded,
                color: enough ? AppColors.green : AppColors.amber, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$count of $maxPhotos photos', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (count / maxPhotos).clamp(0.0, 1.0),
                    minHeight: 6,
                    color: enough ? AppColors.green : AppColors.amber,
                    backgroundColor: AppColors.surfaceAlt,
                  ),
                ),
                const SizedBox(height: 6),
                Text(enough ? 'Ready to submit' : 'Add ${minPhotosToSubmit - count} more to submit for review',
                    style: const TextStyle(color: AppColors.text2, fontSize: 12)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.1,
          children: [
            for (var i = 0; i < photos.length; i++)
              ClipRRect(
                key: ValueKey(photos[i]),
                borderRadius: BorderRadius.circular(16),
                child: Stack(fit: StackFit.expand, children: [
                  NetImage(photos[i], fallback: fallback),
                  const PhotoScrim(strength: 0.55),
                  if (i == 0)
                    const Positioned(
                      left: 8,
                      top: 8,
                      child: Tag('COVER', icon: Icons.star_rounded, color: AppColors.primary, solid: true, dense: true),
                    ),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: _PhotoBtn(icon: Icons.close_rounded, tooltip: 'Remove', onTap: () => _remove(i)),
                  ),
                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 6,
                    child: Row(children: [
                      _PhotoBtn(
                        icon: Icons.chevron_left_rounded,
                        tooltip: 'Move earlier',
                        onTap: i == 0 ? null : () => _move(i, i - 1),
                      ),
                      const Spacer(),
                      if (i != 0)
                        Tap(
                          onTap: () => _move(i, 0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                            child: const Text('Make cover',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.ink)),
                          ),
                        ),
                      const Spacer(),
                      _PhotoBtn(
                        icon: Icons.chevron_right_rounded,
                        tooltip: 'Move later',
                        onTap: i == photos.length - 1 ? null : () => _move(i, i + 1),
                      ),
                    ]),
                  ),
                ]),
              ),
            for (final u in _uploading.values)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(fit: StackFit.expand, children: [
                  if (u.preview != null)
                    Image.memory(u.preview!, fit: BoxFit.cover)
                  else
                    const ColoredBox(color: AppColors.surfaceAlt),
                  ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
                  Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const SizedBox(
                          width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.6, color: Colors.white)),
                      const SizedBox(height: 8),
                      Text(u.stage, style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ]),
              ),
            if (_remaining > 0)
              Tap(
                onTap: _pickSource,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.45), width: 1.5),
                    color: AppColors.primarySoft,
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const IconBubble(Icons.add_a_photo_rounded, color: AppColors.primary, bg: Colors.white, size: 48),
                    const SizedBox(height: 8),
                    const Text('Add photos', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800)),
                    Text('$_remaining slot${_remaining == 1 ? '' : 's'} left',
                        style: const TextStyle(color: AppColors.text2, fontSize: 11.5, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
            'We check every photo: at least 800 × 600 and in focus. Shoot in daylight, landscape, no faces without consent. Max 3 MB each.',
            style: TextStyle(color: AppColors.text3, fontSize: 12, height: 1.4)),
        const SectionTitle('Video tour', subtitle: 'Optional · MP4, up to 2 minutes'),
        AppCard(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            IconBubble(Icons.movie_rounded, color: widget.venue.videoUrl == null ? AppColors.text2 : AppColors.purple, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.venue.videoUrl == null ? 'No video yet' : 'Video tour added',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(
                  widget.venue.videoUrl == null
                      ? 'A 30–60 second walk-through gets more bookings'
                      : 'Members can watch it on your listing',
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                ),
              ]),
            ),
            if (_videoUploading)
              const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
            else if (widget.venue.videoUrl == null)
              TextButton(onPressed: _addVideo, child: const Text('Upload'))
            else
              IconButton(
                tooltip: 'Remove video',
                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red),
                onPressed: () {
                  setState(() => widget.venue.videoUrl = null);
                  widget.onVideoCleared();
                  widget.onChanged();
                },
              ),
          ]),
        ),
      ],
    );
  }
}

class _UserMessage implements Exception {
  const _UserMessage(this.message);
  final String message;
}

class _PhotoBtn extends StatelessWidget {
  const _PhotoBtn({required this.icon, required this.onTap, required this.tooltip});
  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Tap(
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.35 : 1,
          child: Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: Icon(icon, size: 18, color: AppColors.ink),
          ),
        ),
      ),
    );
  }
}
