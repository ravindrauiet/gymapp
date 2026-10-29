import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/studio_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'studio_screen.dart';

/// BRD §7 — one Studio category (e.g. Gym Workouts): video-type chips + Level / Duration / Equipment / Trainer filters.
/// Filtering happens on the server; only filter values that exist in this group are offered.
class StudioGroupScreen extends StatefulWidget {
  const StudioGroupScreen({super.key, required this.group, this.initialType});

  final StudioGroup group;
  final String? initialType;

  @override
  State<StudioGroupScreen> createState() => _StudioGroupScreenState();
}

class _StudioGroupScreenState extends State<StudioGroupScreen> {
  late Future<List<Video>> _future;
  String? _type;
  String? _level;
  String? _duration;
  String? _equipment;
  String? _trainer;

  StudioGroup get g => widget.group;

  bool get _filtered => _level != null || _duration != null || _equipment != null || _trainer != null;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
    _future = _load();
  }

  Future<List<Video>> _load() => context.read<Session>().api.studioVideos(
        group: g.key,
        type: _type,
        level: _level,
        duration: _duration,
        equipment: _equipment,
        trainer: _trainer,
      );

  void _apply(VoidCallback change) => setState(() {
        change();
        _future = _load();
      });

  Future<void> _reload() async {
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* shown by the FutureBuilder */}
  }

  void _clearFilters() => _apply(() {
        _level = null;
        _duration = null;
        _equipment = null;
        _trainer = null;
      });

  /// Bottom sheet with "Any" + each option. Returns '' for Any, null when dismissed.
  Future<void> _pick({
    required String title,
    required List<String> options,
    required String? current,
    required String Function(String) label,
    required ValueChanged<String?> onPicked,
  }) async {
    final picked = await showAppSheet<String>(
      context,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            ),
            Flexible(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(8, 0, 8, 16), children: [
                _SheetOption(label: 'Any', selected: current == null, onTap: () => Navigator.pop(ctx, '')),
                for (final o in options)
                  _SheetOption(label: label(o), selected: current == o, onTap: () => Navigator.pop(ctx, o)),
              ]),
            ),
          ]),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    final value = picked.isEmpty ? null : picked;
    if (value != current) _apply(() => onPicked(value));
  }

  @override
  Widget build(BuildContext context) {
    final visual = g.visual;
    final f = g.filters;
    final typeLabel = {for (final t in g.types) t.key: t.label};

    final chips = <Widget>[
      if (f.levels.length > 1)
        _FilterChip(
          label: 'Level',
          value: _level == null ? null : studioLevelLabel(_level!),
          icon: Icons.signal_cellular_alt_rounded,
          onTap: () => _pick(
            title: 'Level',
            options: f.levels,
            current: _level,
            label: studioLevelLabel,
            onPicked: (v) => _level = v,
          ),
        ),
      if (f.durations.length > 1)
        _FilterChip(
          label: 'Duration',
          value: _duration == null ? null : studioDurationLabel(_duration!),
          icon: Icons.schedule_rounded,
          onTap: () => _pick(
            title: 'Duration',
            options: f.durations,
            current: _duration,
            label: studioDurationLabel,
            onPicked: (v) => _duration = v,
          ),
        ),
      if (f.equipment.length > 1)
        _FilterChip(
          label: 'Equipment',
          value: _equipment == null ? null : studioEquipmentLabel(_equipment!),
          icon: Icons.fitness_center_rounded,
          onTap: () => _pick(
            title: 'Equipment',
            options: f.equipment,
            current: _equipment,
            label: studioEquipmentLabel,
            onPicked: (v) => _equipment = v,
          ),
        ),
      if (f.trainers.length > 1)
        _FilterChip(
          label: 'Trainer',
          value: _trainer,
          icon: Icons.person_rounded,
          onTap: () => _pick(
            title: 'Coach',
            options: f.trainers,
            current: _trainer,
            label: (t) => t,
            onPicked: (v) => _trainer = v,
          ),
        ),
    ];

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(g.label)),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: PhotoBanner(
                image: visual.image,
                eyebrow: 'FitKey studio',
                title: g.label,
                subtitle: '${g.count} video${g.count == 1 ? '' : 's'} by FITKEY coaches',
                height: 150,
              ),
            ),
            if (g.types.isNotEmpty) ...[
              const SizedBox(height: 16),
              ChoiceChips<String?>(
                options: [null, ...g.types.map((t) => t.key)],
                selected: _type,
                label: (k) => k == null ? 'All' : typeLabel[k] ?? k,
                onSelected: (k) => _apply(() => _type = k),
              ),
            ],
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 38,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(Icons.tune_rounded, size: 20, color: AppColors.text2),
                    ),
                    for (final c in chips) Padding(padding: const EdgeInsets.only(right: 8), child: c),
                    if (_filtered)
                      TextButton(onPressed: _clearFilters, child: const Text('Clear')),
                  ],
                ),
              ),
            ],
            FutureBuilder<List<Video>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Shimmer(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Column(children: [
                        SkeletonBox(height: 200, radius: 18),
                        SizedBox(height: 18),
                        SkeletonBox(height: 200, radius: 18),
                      ]),
                    ),
                  );
                }
                if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
                final videos = snap.data!;
                if (videos.isEmpty) {
                  return EmptyView(
                    icon: Icons.filter_alt_off_rounded,
                    color: visual.color,
                    title: 'No videos match',
                    message: 'Try a different type or loosen your filters.',
                    action: SizedBox(
                      width: 200,
                      child: OutlinedButton(
                        onPressed: () => _apply(() {
                          _type = null;
                          _level = null;
                          _duration = null;
                          _equipment = null;
                          _trainer = null;
                        }),
                        child: const Text('Show all'),
                      ),
                    ),
                  );
                }
                final wide = MediaQuery.sizeOf(context).width >= 640;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text('${videos.length} video${videos.length == 1 ? '' : 's'}',
                          style: const TextStyle(fontSize: 13, color: AppColors.text2, fontWeight: FontWeight.w700)),
                    ),
                    if (wide)
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        itemCount: videos.length,
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2, mainAxisSpacing: 18, crossAxisSpacing: 14, childAspectRatio: 1.15),
                        itemBuilder: (_, i) => VideoTile(video: videos[i]),
                      )
                    else
                      for (final v in videos)
                        Padding(padding: const EdgeInsets.only(bottom: 20), child: VideoTile(video: v)),
                  ]),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.value, required this.icon, required this.onTap});
  final String label;
  final String? value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final on = value != null;
    return Tap(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? AppColors.primarySoft : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? AppColors.primary : AppColors.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: on ? AppColors.primary : AppColors.text2),
          const SizedBox(width: 6),
          Text(value ?? label,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: on ? AppColors.primary : AppColors.text)),
          const SizedBox(width: 2),
          Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: on ? AppColors.primary : AppColors.text2),
        ]),
      ),
    );
  }
}

class _SheetOption extends StatelessWidget {
  const _SheetOption({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(label, style: TextStyle(fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
      trailing: selected ? const Icon(Icons.check_circle_rounded, color: AppColors.primary) : null,
      onTap: onTap,
    );
  }
}
