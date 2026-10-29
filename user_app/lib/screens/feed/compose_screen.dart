import 'dart:typed_data';

import 'package:fitkey_core/fitkey_core.dart' show apiDate, formatDate;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/feed_api.dart';
import '../../data/fitkey_api.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'face_blur.dart';
import 'feed_widgets.dart';

/// A picked or already-uploaded photo.
class _Media {
  _Media.remote(this.url);
  _Media.local(this.original, this.bytes);

  XFile? original;
  Uint8List? bytes;
  String? url;
  bool uploading = false;
  bool failed = false;

  Widget preview({double? height, double radius = 14}) => bytes != null
      ? ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Image.memory(bytes!, fit: BoxFit.cover, width: double.infinity, height: height ?? double.infinity),
        )
      : NetImage(url, fallback: AppImages.gymFloor, radius: radius, height: height);
}

/// Create or edit a FitFeed post: `photo` (1–10 images + caption), `blog` (title, cover, light Markdown, inline images)
/// or `journey` (before / after photos, start / current stats; stats can be pulled from Progress & Fuel Log).
/// Pops with the saved [FeedPost].
class ComposePostScreen extends StatefulWidget {
  const ComposePostScreen({super.key, required this.kind, this.existing});
  final String kind;
  final FeedPost? existing;

  @override
  State<ComposePostScreen> createState() => _ComposePostScreenState();
}

class _ComposePostScreenState extends State<ComposePostScreen> {
  late final FeedPost? _e = widget.existing;
  late String? _category = _e?.category;
  late String _visibility = _e?.visibility ?? 'public';
  late final _caption = TextEditingController(text: _e?.caption ?? '');
  late final _title = TextEditingController(text: _e?.title ?? '');
  late final _body = TextEditingController(text: _e?.body ?? '');
  late final List<_Media> _photos = [for (final u in _e?.images ?? const <String>[]) _Media.remote(u)];
  late _Media? _cover = _e?.coverUrl == null ? null : _Media.remote(_e!.coverUrl);
  bool _preview = false;

  // Journey
  late String _goal = _e?.journey?.goal ?? 'weight_loss';
  late _Media? _before = _e?.journey?.beforeUrl == null ? null : _Media.remote(_e!.journey!.beforeUrl);
  late _Media? _after = _e?.journey?.afterUrl == null ? null : _Media.remote(_e!.journey!.afterUrl);
  late bool _blur = _e?.facesBlurred ?? false;
  late final _startWeight = TextEditingController(text: _num(_e?.journey?.start.weightKg));
  late DateTime? _startDate = DateTime.tryParse(_e?.journey?.start.date ?? '');
  late final _curWeight = TextEditingController(text: _num(_e?.journey?.current.weightKg));
  late final _curFat = TextEditingController(text: _num(_e?.journey?.current.bodyFatPct));
  late final _curWaist = TextEditingController(text: _num(_e?.journey?.current.waistCm));
  late final _curKcal = TextEditingController(text: _num(_e?.journey?.current.calories?.toDouble()));
  late final _curProtein = TextEditingController(text: _num(_e?.journey?.current.proteinG));
  bool _pulling = false;

  bool _busy = false;
  final _picker = ImagePicker();

  static String _num(double? v) => v == null ? '' : (v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1));
  static double? _parse(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));

  bool get _isEdit => _e != null;
  bool get _wasPublished => _e != null && !_e.isDraft;

  @override
  void dispose() {
    for (final c in [_caption, _title, _body, _startWeight, _curWeight, _curFat, _curWaist, _curKcal, _curProtein]) {
      c.dispose();
    }
    super.dispose();
  }

  FitkeyApi get _api => context.read<Session>().api;

  // ---- Media -----------------------------------------------------------------

  Future<_Media?> _pickOne() async {
    final f = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
    if (f == null) return null;
    return _Media.local(f, await f.readAsBytes());
  }

  Future<void> _upload(_Media m, {bool blur = false}) async {
    final api = _api;
    setState(() {
      m.uploading = true;
      m.failed = false;
    });
    try {
      var file = m.original!;
      if (blur && faceBlurSupported) {
        final r = await blurFaces(file);
        file = r.file;
        final bytes = await file.readAsBytes();
        if (mounted) {
          setState(() => m.bytes = bytes);
          toast(context, r.faces == 0 ? 'No face found in this photo' : 'Blurred ${r.faces} ${r.faces == 1 ? 'face' : 'faces'}',
              icon: Icons.blur_on_rounded);
        }
      }
      final url = await api.upload(file);
      if (mounted) setState(() => m.url = url);
    } catch (e) {
      if (mounted) {
        setState(() => m.failed = true);
        toast(context, friendlyError(e), error: true);
      }
    } finally {
      if (mounted) setState(() => m.uploading = false);
    }
  }

  Future<void> _addPhotos() async {
    final remaining = 10 - _photos.length;
    if (remaining <= 0) return;
    final files = await _picker.pickMultiImage(maxWidth: 1600, imageQuality: 85, limit: remaining >= 2 ? remaining : null);
    for (final f in files.take(remaining)) {
      final m = _Media.local(f, await f.readAsBytes());
      if (!mounted) return;
      setState(() => _photos.add(m));
      _upload(m);
    }
  }

  Future<void> _pickCover() async {
    final m = await _pickOne();
    if (m == null || !mounted) return;
    setState(() => _cover = m);
    _upload(m);
  }

  Future<void> _pickJourney(bool before) async {
    final m = await _pickOne();
    if (m == null || !mounted) return;
    setState(() => before ? _before = m : _after = m);
    _upload(m, blur: _blur);
  }

  void _setBlur(bool v) {
    setState(() => _blur = v);
    for (final m in [_before, _after]) {
      if (m == null) continue;
      if (m.original != null) {
        // Re-process from the original pick so the toggle can also be switched off.
        m.url = null;
        m.original!.readAsBytes().then((b) {
          if (!mounted) return;
          setState(() => m.bytes = b);
          _upload(m, blur: v);
        });
      } else if (v) {
        toast(context, 'Re-pick your photos to blur faces in them', icon: Icons.blur_on_rounded);
      }
    }
  }

  // ---- Blog editor helpers -----------------------------------------------------

  void _insert(String before, [String after = '', bool lineStart = false]) {
    final t = _body.text;
    var sel = _body.selection;
    if (!sel.isValid) sel = TextSelection.collapsed(offset: t.length);
    var start = sel.start, end = sel.end;
    if (lineStart) {
      start = end = t.lastIndexOf('\n', start == 0 ? 0 : start - 1) + 1;
      if (sel.start == 0) start = end = 0;
    }
    final selected = t.substring(start, end);
    final text = t.replaceRange(start, end, '$before$selected$after');
    _body.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + before.length + selected.length + (selected.isEmpty ? 0 : after.length)),
    );
  }

  Future<void> _insertImage() async {
    final m = await _pickOne();
    if (m == null || !mounted) return;
    final api = _api;
    toast(context, 'Uploading image…', icon: Icons.cloud_upload_rounded);
    try {
      final url = await api.upload(m.original!);
      if (!mounted) return;
      final t = _body.text;
      final at = _body.selection.isValid ? _body.selection.end : t.length;
      final needsBreak = at > 0 && t[at - 1] != '\n';
      final snippet = '${needsBreak ? '\n' : ''}![]($url)\n';
      _body.value = TextEditingValue(
        text: t.replaceRange(at, at, snippet),
        selection: TextSelection.collapsed(offset: at + snippet.length),
      );
      toast(context, 'Image added');
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  // ---- Journey: pull stats -----------------------------------------------------

  Future<void> _pullStats() async {
    final api = _api;
    setState(() => _pulling = true);
    final results = await Future.wait<Object?>([
      api.healthReport(days: 365).then<Object?>((r) => r).catchError((_) => null),
      api.goal().then<Object?>((g) => g).catchError((_) => null),
      api.dailyMeals().then<Object?>((m) => m).catchError((_) => null),
    ]);
    if (!mounted) return;
    final report = results[0] as HealthReport?;
    final goal = results[1] as UserGoal?;
    final meals = results[2] as MealDailySummary?;
    var filled = 0;
    setState(() {
      _pulling = false;
      final weights = [...?report?.weightSeries]..sort((a, b) => a.loggedOn.compareTo(b.loggedOn));
      if (weights.isNotEmpty) {
        _startWeight.text = _num(weights.first.weightKg);
        _startDate = weights.first.loggedOn;
        filled++;
      }
      final latest = report?.latestWeight?.weightKg ?? goal?.currentWeightKg;
      if (latest != null) {
        _curWeight.text = _num(latest);
        filled++;
      }
      if (goal != null) {
        _goal = switch (goal.goalType) {
          'weight_loss' => 'weight_loss',
          'muscle_gain' => 'weight_gain',
          _ => 'fitness',
        };
      }
      final kcal = (meals?.totalCalories ?? 0) > 0 ? meals!.totalCalories : report?.nutrition?.avgDailyCalories;
      if (kcal != null && kcal > 0) {
        _curKcal.text = '$kcal';
        filled++;
      }
      final protein = (meals?.totalProteinG ?? 0) > 0 ? meals!.totalProteinG : report?.nutrition?.avgDailyProtein;
      if (protein != null && protein > 0) {
        _curProtein.text = _num(protein);
        filled++;
      }
    });
    toast(context, filled == 0 ? 'No weight or meal logs yet — enter your stats below' : 'Filled from your Progress & Fuel Log',
        error: false, icon: filled == 0 ? Icons.info_outline_rounded : Icons.auto_awesome_rounded);
  }

  // ---- Save --------------------------------------------------------------------

  Json _fields(String status) {
    final f = <String, dynamic>{
      'status': status,
      'visibility': _visibility,
      'category': _category,
      'caption': _caption.text.trim().isEmpty ? null : _caption.text.trim(),
    };
    switch (widget.kind) {
      case 'photo':
        f['images'] = [for (final m in _photos) ?m.url];
      case 'blog':
        f['title'] = _title.text.trim().isEmpty ? null : _title.text.trim();
        f['body'] = _body.text.trim().isEmpty ? null : _body.text.trim();
        f['coverUrl'] = _cover?.url;
        f['caption'] = null;
      case 'journey':
        f['facesBlurred'] = _blur;
        f['journey'] = JourneyData(
          goal: _goal,
          beforeUrl: _before?.url,
          afterUrl: _after?.url,
          start: JourneyStats(weightKg: _parse(_startWeight), date: _startDate == null ? null : apiDate(_startDate!)),
          current: JourneyStats(
            weightKg: _parse(_curWeight),
            bodyFatPct: _parse(_curFat),
            waistCm: _parse(_curWaist),
            calories: _parse(_curKcal)?.round(),
            proteinG: _parse(_curProtein),
          ),
        ).toJson();
    }
    return f;
  }

  String? _problem(bool publish) {
    final all = [..._photos, ?_cover, ?_before, ?_after];
    if (all.any((m) => m.uploading)) return 'Hang on — photos are still uploading';
    if (all.any((m) => m.failed)) return 'A photo failed to upload — remove it or pick it again';
    if (!publish) return null;
    switch (widget.kind) {
      case 'photo':
        if (_photos.isEmpty) return 'Add at least one photo';
      case 'blog':
        if (_title.text.trim().length < 3) return 'Give your blog a title';
        if (_body.text.trim().length < 20) return 'Your blog needs a little more text';
      case 'journey':
        if (_before?.url == null || _after?.url == null) return 'Add a before and an after photo';
    }
    for (final c in [_startWeight, _curWeight, _curFat, _curWaist, _curKcal, _curProtein]) {
      if (c.text.trim().isNotEmpty && _parse(c) == null) return 'Check your stats — numbers only';
    }
    return null;
  }

  Future<void> _save({required bool publish}) async {
    final problem = _problem(publish);
    if (problem != null) {
      toast(context, problem, error: true);
      return;
    }
    final api = _api;
    final status = publish ? 'published' : 'draft';
    setState(() => _busy = true);
    try {
      final FeedPost post;
      if (_isEdit) {
        post = await api.updateFeedPost(_e!.id, _fields(status));
      } else {
        post = await api.createFeedPost({'kind': widget.kind, ..._fields(status)});
      }
      if (!post.isDraft && !_wasPublished) {
        FeedBus.emit(PostCreated(post));
      } else {
        FeedBus.emit(PostEdited(post));
      }
      if (!mounted) return;
      toast(context, post.isDraft ? 'Saved to drafts' : (_wasPublished ? 'Post updated' : 'Posted to FitFeed 🎉'));
      Navigator.pop(context, post);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, friendlyError(e), error: true);
      }
    }
  }

  // ---- UI ----------------------------------------------------------------------

  String get _title2 => switch (widget.kind) {
        'blog' => _isEdit ? 'Edit blog' : 'New blog',
        'journey' => _isEdit ? 'Edit journey' : 'Share your journey',
        _ => _isEdit ? 'Edit post' : 'New photo post',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(_title2),
        actions: [
          if (!_wasPublished)
            TextButton(onPressed: _busy ? null : () => _save(publish: false), child: const Text('Save draft')),
          const SizedBox(width: 6),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          ...switch (widget.kind) {
            'blog' => _blogEditor(),
            'journey' => _journeyEditor(),
            _ => _photoEditor(),
          },
          const SectionTitle('Category', padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
          ChoiceChips<String?>(
            padding: EdgeInsets.zero,
            options: [null, ...feedCategories.keys],
            selected: _category,
            onSelected: (c) => setState(() => _category = c),
            label: (c) => c == null ? 'None' : feedCategories[c]!,
            icon: (c) => c == null ? null : categoryLook(c).icon,
          ),
          const SectionTitle('Who can see this', padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'public', icon: Icon(Icons.public_rounded), label: Text('Everyone')),
              ButtonSegment(value: 'followers', icon: Icon(Icons.group_rounded), label: Text('Followers')),
            ],
            selected: {_visibility},
            onSelectionChanged: (s) => setState(() => _visibility = s.first),
          ),
        ],
      ),
      bottomNavigationBar: BottomActionBar(
        child: AppButton(
          label: _wasPublished ? 'Save changes' : 'Publish',
          icon: _wasPublished ? Icons.check_rounded : Icons.send_rounded,
          busy: _busy,
          onPressed: () => _save(publish: true),
        ),
      ),
    );
  }

  Widget _mediaTile(_Media m, {required VoidCallback onRemove, double size = 104}) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(fit: StackFit.expand, children: [
        m.preview(),
        if (m.uploading)
          Container(
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(14)),
            alignment: Alignment.center,
            child: const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)),
          ),
        if (m.failed)
          Container(
            decoration: BoxDecoration(color: AppColors.red.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(14)),
            alignment: Alignment.center,
            child: IconButton(
              onPressed: () => _upload(m),
              icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            ),
          ),
        Positioned(
          top: 4,
          right: 4,
          child: Tap(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded, size: 15, color: Colors.white),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _addTile({required String label, required VoidCallback onTap, double width = 104, double height = 104, IconData? icon}) {
    return Tap(
      onTap: onTap,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon ?? Icons.add_photo_alternate_rounded, color: AppColors.primary, size: 28),
          const SizedBox(height: 6),
          Text(label, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 12.5)),
        ]),
      ),
    );
  }

  List<Widget> _photoEditor() => [
        Text('Photos · ${_photos.length}/10', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in _photos) _mediaTile(m, onRemove: () => setState(() => _photos.remove(m))),
          if (_photos.length < 10) _addTile(label: _photos.isEmpty ? 'Add photos' : 'Add more', onTap: _addPhotos),
        ]),
        const SizedBox(height: 18),
        TextField(
          controller: _caption,
          minLines: 3,
          maxLines: 8,
          maxLength: 2200,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Write a caption — what did you train today? Any tips?'),
        ),
      ];

  List<Widget> _blogEditor() => [
        if (_cover == null)
          _addTile(label: 'Add a cover photo', onTap: _pickCover, width: double.infinity, height: 170, icon: Icons.image_rounded)
        else
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(fit: StackFit.expand, children: [
              _cover!.preview(radius: 18),
              if (_cover!.uploading)
                const Center(child: CircularProgressIndicator(color: Colors.white)),
              Positioned(
                right: 10,
                bottom: 10,
                child: FilledButton.tonalIcon(
                  onPressed: _pickCover,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                  label: const Text('Change'),
                ),
              ),
            ]),
          ),
        const SizedBox(height: 14),
        TextField(
          controller: _title,
          maxLength: 160,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5),
          decoration: const InputDecoration(hintText: 'Title', counterText: ''),
        ),
        const SizedBox(height: 12),
        Row(children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.edit_rounded, size: 17), label: Text('Write')),
              ButtonSegment(value: true, icon: Icon(Icons.visibility_rounded, size: 17), label: Text('Preview')),
            ],
            selected: {_preview},
            onSelectionChanged: (s) {
              FocusScope.of(context).unfocus();
              setState(() => _preview = s.first);
            },
          ),
          const Spacer(),
        ]),
        const SizedBox(height: 10),
        if (_preview)
          AppCard(
            child: _body.text.trim().isEmpty
                ? const Text('Nothing to preview yet.', style: TextStyle(color: AppColors.text3))
                : BlogBody(_body.text),
          )
        else ...[
          Container(
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
            child: Row(children: [
              IconButton(tooltip: 'Heading', onPressed: () => _insert('## ', '', true), icon: const Icon(Icons.title_rounded)),
              IconButton(tooltip: 'Bold', onPressed: () => _insert('**', '**'), icon: const Icon(Icons.format_bold_rounded)),
              IconButton(tooltip: 'Bullet', onPressed: () => _insert('- ', '', true), icon: const Icon(Icons.format_list_bulleted_rounded)),
              IconButton(
                  tooltip: 'Numbered', onPressed: () => _insert('1. ', '', true), icon: const Icon(Icons.format_list_numbered_rounded)),
              const Spacer(),
              TextButton.icon(onPressed: _insertImage, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('Image')),
            ]),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _body,
            minLines: 12,
            maxLines: null,
            maxLength: 20000,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 15.5, height: 1.5),
            decoration: const InputDecoration(
              hintText: 'Share your knowledge…\n\n## Use headings\n**Bold** the key points\n- and bullet lists',
              alignLabelWithHint: true,
            ),
          ),
        ],
      ];

  Widget _statField(TextEditingController c, String label, String suffix) => Expanded(
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, suffixText: suffix, isDense: true),
        ),
      );

  List<Widget> _journeyEditor() {
    Widget slot(String label, _Media? m, bool before) => Expanded(
          child: AspectRatio(
            aspectRatio: 4 / 5,
            child: m == null
                ? _addTile(label: 'Add $label photo', onTap: () => _pickJourney(before), width: double.infinity, height: double.infinity)
                : Stack(fit: StackFit.expand, children: [
                    _mediaTile(m, onRemove: () => setState(() => before ? _before = null : _after = null)),
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Tag(label.toUpperCase(), color: AppColors.ink, bg: Colors.white, dense: true),
                    ),
                  ]),
          ),
        );
    return [
      Row(children: [slot('before', _before, true), const SizedBox(width: 10), slot('after', _after, false)]),
      const SizedBox(height: 12),
      if (!kIsWeb && faceBlurSupported)
        AppCard(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          shadow: false,
          border: true,
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _blur,
            onChanged: _setBlur,
            secondary: const IconBubble(Icons.blur_on_rounded, color: AppColors.teal, size: 38),
            title: const Text('Blur my face', style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('Done on your phone before upload', style: TextStyle(fontSize: 12.5)),
          ),
        ),
      const SectionTitle('Goal', padding: EdgeInsets.fromLTRB(0, 20, 0, 10)),
      ChoiceChips<String>(
        padding: EdgeInsets.zero,
        options: const ['weight_loss', 'weight_gain', 'fitness'],
        selected: _goal,
        onSelected: (g) => setState(() => _goal = g),
        label: (g) => switch (g) {
          'weight_loss' => 'Weight loss',
          'weight_gain' => 'Weight gain',
          _ => 'Fitness',
        },
        icon: (g) => switch (g) {
          'weight_loss' => Icons.trending_down_rounded,
          'weight_gain' => Icons.trending_up_rounded,
          _ => Icons.bolt_rounded,
        },
      ),
      const SizedBox(height: 18),
      AppCard(
        color: AppColors.purpleSoft,
        shadow: false,
        onTap: _pulling ? null : _pullStats,
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          const IconBubble(Icons.auto_awesome_rounded, color: AppColors.purple, bg: Colors.white, size: 40),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Pull my stats', style: TextStyle(fontWeight: FontWeight.w800)),
              Text('From Progress & Fuel Log — one tap, optional', style: TextStyle(fontSize: 12.5, color: AppColors.text2)),
            ]),
          ),
          _pulling
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.purple))
              : const Icon(Icons.download_rounded, color: AppColors.purple),
        ]),
      ),
      const SectionTitle('Start', padding: EdgeInsets.fromLTRB(0, 20, 0, 10)),
      Row(children: [
        _statField(_startWeight, 'Weight', 'kg'),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                context: context,
                firstDate: DateTime(now.year - 10),
                lastDate: now,
                initialDate: _startDate ?? now.subtract(const Duration(days: 90)),
              );
              if (d != null && mounted) setState(() => _startDate = d);
            },
            icon: const Icon(Icons.event_rounded, size: 18),
            label: Text(_startDate == null ? 'Start date' : formatDate(_startDate!)),
          ),
        ),
      ]),
      const SectionTitle('Now', padding: EdgeInsets.fromLTRB(0, 20, 0, 10)),
      Row(children: [_statField(_curWeight, 'Weight', 'kg'), const SizedBox(width: 10), _statField(_curFat, 'Body fat', '%')]),
      const SizedBox(height: 10),
      Row(children: [_statField(_curWaist, 'Waist', 'cm'), const SizedBox(width: 10), _statField(_curKcal, 'Daily intake', 'kcal')]),
      const SizedBox(height: 10),
      Row(children: [_statField(_curProtein, 'Protein', 'g/day'), const SizedBox(width: 10), const Spacer()]),
      const SizedBox(height: 18),
      TextField(
        controller: _caption,
        minLines: 3,
        maxLines: 8,
        maxLength: 2200,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Tell your story — what changed, what worked, what you\'d tell someone starting out'),
      ),
      if (_isEdit)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('Tip: add timeline updates from the post page as you progress.', style: TextStyle(color: AppColors.text3, fontSize: 12.5)),
        ),
    ];
  }
}
