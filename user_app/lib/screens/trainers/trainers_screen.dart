import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart' show formatPaise, formatDayDate;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/ratings_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../../widgets/rating_prompt.dart';
import '../../widgets/rating_widgets.dart';
import 'trainer_detail_screen.dart';

/// How a backend training mode (`online` | `home` | `gym`) is shown.
class TrainerMode {
  const TrainerMode(this.id, this.label, this.long, this.icon, this.color);
  final String id;
  final String label;
  final String long;
  final IconData icon;
  final Color color;

  static const all = [
    TrainerMode('online', 'Online', 'Live video session', Icons.videocam_rounded, AppColors.purple),
    TrainerMode('home', 'At home', 'Trainer comes to you', Icons.home_rounded, AppColors.teal),
    TrainerMode('gym', 'At gym', 'At a partner gym', Icons.fitness_center_rounded, AppColors.primary),
  ];

  static TrainerMode of(String id) =>
      all.firstWhere((m) => m.id == id, orElse: () => TrainerMode(id, id, id, Icons.bolt_rounded, AppColors.text2));
}

/// Parses a booking's "YYYY-MM-DD" + "06:30 AM" into a local DateTime.
DateTime? sessionStart(String date, String slot) {
  final d = DateTime.tryParse(date);
  if (d == null) return null;
  final m = RegExp(r'^(\d{1,2}):(\d{2})\s*([AaPp][Mm])?$').firstMatch(slot.trim());
  if (m == null) return d;
  var h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  final ap = m.group(3)?.toUpperCase();
  if (ap == 'PM' && h < 12) h += 12;
  if (ap == 'AM' && h == 12) h = 0;
  return DateTime(d.year, d.month, d.day, h, min);
}

/// FitPro On-Demand — find and book certified personal trainers.
class TrainersScreen extends StatefulWidget {
  const TrainersScreen({super.key});

  @override
  State<TrainersScreen> createState() => _TrainersScreenState();
}

class _TrainersScreenState extends State<TrainersScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _search = TextEditingController();
  Timer? _debounce;

  String? _mode; // null = any mode
  String? _group; // null = all groups (BRD §6 categories)
  String? _type; // sub-type inside [_group]
  String _sort = 'relevance'; // relevance | rating | price_low | price_high
  double? _minRating;
  List<TrainerCategoryGroup> _groups = const [];

  static const _sortLabels = {
    'relevance': 'Relevance',
    'rating': 'Top rated',
    'price_low': 'Price: low to high',
    'price_high': 'Price: high to low',
  };

  late Future<List<Trainer>> _future;
  late Future<List<TrainerBooking>> _bookings;

  @override
  void initState() {
    super.initState();
    _future = _loadTrainers();
    _bookings = context.read<Session>().api.myTrainerBookings();
    _loadGroups();
  }

  Future<void> _loadGroups() async {
    try {
      final g = await context.read<Session>().api.trainerCategories();
      if (!mounted) return;
      setState(() => _groups = g);
    } catch (_) {
      // Category chips are optional; the list still works without them.
    }
  }

  TrainerCategoryGroup? get _selectedGroup {
    for (final g in _groups) {
      if (g.key == _group) return g;
    }
    return null;
  }

  Future<void> _pickSort() async {
    final picked = await showAppSheet<String>(
      context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Sort trainers by', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            for (final e in _sortLabels.entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(e.value, style: TextStyle(fontWeight: e.key == _sort ? FontWeight.w800 : FontWeight.w600)),
                trailing: e.key == _sort ? const Icon(Icons.check_circle_rounded, color: AppColors.primary) : null,
                onTap: () => Navigator.pop(ctx, e.key),
              ),
          ]),
        ),
      ),
    );
    if (picked != null && picked != _sort && mounted) {
      _sort = picked;
      _reloadTrainers();
    }
  }

  Future<void> _rateBooking(TrainerBooking b) async {
    final api = context.read<Session>().api;
    MyRating? mine;
    try {
      mine = (await api.ratingSummary('trainer', b.trainerId)).myRating;
    } catch (_) {}
    if (!mounted) return;
    final res = await showRatingSheet(
      context,
      targetType: 'trainer',
      targetId: b.trainerId,
      name: b.trainerName,
      subtitle: '${TrainerMode.of(b.mode).label} session · ${b.slotTime}',
      photoUrl: b.photoUrl,
      fallbackImage: AppImages.homeWorkout,
      initial: mine,
    );
    if (res != null && mounted) _reloadTrainers();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Future<List<Trainer>> _loadTrainers() async {
    final q = _search.text.trim();
    return context.read<Session>().api.trainersFiltered(
      modes: _mode,
      group: _group,
      type: _type,
      q: q.isEmpty ? null : q,
      sort: _sort,
      minRating: _minRating,
    );
  }

  Future<void> _reloadTrainers() async {
    final f = _loadTrainers();
    setState(() => _future = f);
    await f;
  }

  Future<void> _reloadBookings() async {
    final f = context.read<Session>().api.myTrainerBookings();
    setState(() => _bookings = f);
    await f;
  }

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _reloadTrainers();
    });
  }

  Future<void> _open(Trainer t) async {
    final booked = await push<bool>(context, TrainerDetailScreen(trainerId: t.id));
    if (!mounted) return;
    if (booked == true) {
      _reloadBookings();
      _tabs.animateTo(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Book a trainer'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Find trainers'),
            Tab(text: 'My bookings'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildFind(),
          _MyBookings(
            future: _bookings,
            onRefresh: _reloadBookings,
            onFind: () => _tabs.animateTo(0),
            onRate: _rateBooking,
          ),
        ],
      ),
    );
  }

  Widget _buildFind() {
    final group = _selectedGroup;
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: () async {
        _loadGroups();
        await _reloadTrainers();
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              color: AppColors.surface,
              padding: const EdgeInsets.only(top: 14, bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: RotatingSearchBar(
                      hints: const [
                        "'yoga coach'",
                        "'strength training'",
                        "'boxing'",
                        "'swimming coach'",
                        "'weight loss'",
                      ],
                      controller: _search,
                      onChanged: _onSearch,
                      onSubmitted: (_) {
                        _debounce?.cancel();
                        _reloadTrainers();
                      },
                    ),
                  ),
                  if (_groups.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    ChoiceChips<String?>(
                      options: [null, ..._groups.map((g) => g.key)],
                      selected: _group,
                      label: (g) => g == null ? 'All trainers' : _groups.firstWhere((x) => x.key == g).label,
                      icon: (g) => g == null ? Icons.apps_rounded : trainerGroupIcon(g),
                      onSelected: (g) {
                        if (g == _group) return;
                        _group = g;
                        _type = null;
                        _reloadTrainers();
                      },
                    ),
                  ],
                  if (group != null && group.types.length > 1) ...[
                    const SizedBox(height: 10),
                    _SpecChips(
                      specs: group.types.map((t) => t.key).toList(),
                      labelOf: (k) => group.types.firstWhere((t) => t.key == k).label,
                      selected: _type,
                      onSelected: (k) {
                        _type = k == _type ? null : k;
                        _reloadTrainers();
                      },
                    ),
                  ],
                  const SizedBox(height: 10),
                  ChoiceChips<String?>(
                    options: [null, ...TrainerMode.all.map((m) => m.id)],
                    selected: _mode,
                    label: (m) => m == null ? 'Any mode' : TrainerMode.of(m).label,
                    icon: (m) => m == null ? Icons.tune_rounded : TrainerMode.of(m).icon,
                    onSelected: (m) {
                      if (m == _mode) return;
                      _mode = m;
                      _reloadTrainers();
                    },
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        _FilterPill(
                          icon: Icons.swap_vert_rounded,
                          label: 'Sort: ${_sortLabels[_sort]}',
                          on: _sort != 'relevance',
                          dropdown: true,
                          onTap: _pickSort,
                        ),
                        const SizedBox(width: 8),
                        _FilterPill(
                          icon: Icons.star_rounded,
                          label: 'Rated 4.0+',
                          on: _minRating != null,
                          onTap: () {
                            _minRating = _minRating == null ? 4 : null;
                            _reloadTrainers();
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          FutureBuilder<List<Trainer>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SliverToBoxAdapter(child: _TrainerSkeleton());
              }
              if (snap.hasError) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorView(error: snap.error!, onRetry: _reloadTrainers),
                );
              }
              final list = snap.data!;
              if (list.isEmpty) {
                final filtered =
                    _mode != null || _group != null || _minRating != null || _search.text.trim().isNotEmpty;
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyView(
                    icon: Icons.sports_rounded,
                    color: AppColors.blue,
                    title: 'No trainers found',
                    message: filtered
                        ? (_minRating != null
                              ? 'No trainers rated 4.0+ yet — averages appear after $kRatingsUntilAverage rated sessions.'
                              : 'Try a different search or clear your filters.')
                        : 'Certified trainers will show up here as they join.',
                    action: filtered
                        ? SizedBox(
                            width: 180,
                            child: OutlinedButton(
                              onPressed: () {
                                _search.clear();
                                _mode = null;
                                _group = null;
                                _type = null;
                                _minRating = null;
                                _sort = 'relevance';
                                _reloadTrainers();
                              },
                              child: const Text('Clear filters'),
                            ),
                          )
                        : null,
                  ),
                );
              }
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                sliver: SliverList.list(
                  children: [
                    SectionTitle(
                      '${list.length} trainer${list.length == 1 ? '' : 's'} available',
                      subtitle: 'Verified & certified · 60-min sessions',
                      padding: const EdgeInsets.fromLTRB(0, 18, 0, 12),
                    ),
                    for (final t in list) ...[
                      _TrainerCard(trainer: t, onTap: () => _open(t)),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SpecChips extends StatelessWidget {
  const _SpecChips({required this.specs, required this.labelOf, required this.selected, required this.onSelected});
  final List<String> specs;
  final String Function(String) labelOf;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: specs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final s = specs[i];
          final on = s == selected;
          return Tap(
            onTap: () => onSelected(s),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? AppColors.primarySoft : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: on ? AppColors.primary : Colors.transparent),
              ),
              child: Row(
                children: [
                  Text(
                    labelOf(s),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: on ? AppColors.primary : AppColors.text2,
                    ),
                  ),
                  if (on) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.close_rounded, size: 14, color: AppColors.primary),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Urban Company–style professional card.
class _TrainerCard extends StatelessWidget {
  const _TrainerCard({required this.trainer, required this.onTap});
  final Trainer trainer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = trainer;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                height: 116,
                child: NetImage(t.photoUrl, fallback: AppImages.homeWorkout, radius: 16),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.verified_rounded, size: 17, color: AppColors.blue),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _RatingRow(rating: t.rating, reviews: t.reviewCount),
                    const SizedBox(height: 8),
                    if (t.trainerTypeLabels.isNotEmpty || t.specializations.isNotEmpty)
                      Text(
                        (t.trainerTypeLabels.isNotEmpty ? t.trainerTypeLabels : t.specializations).join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppColors.text2,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    const SizedBox(height: 8),
                    if (t.certifications.isNotEmpty)
                      Tag(
                        t.certifications.length == 1 ? '1 certification' : '${t.certifications.length} certifications',
                        icon: Icons.workspace_premium_rounded,
                        color: AppColors.green,
                        dense: true,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final m in t.trainingModes) ...[
                Tooltip(
                  message: TrainerMode.of(m).label,
                  child: IconBubble(TrainerMode.of(m).icon, color: TrainerMode.of(m).color, size: 28, iconSize: 15),
                ),
                const SizedBox(width: 6),
              ],
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatPaise(t.hourlyRatePaise),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                  ),
                  const Text(
                    'per session',
                    style: TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(12)),
                child: const Text(
                  'Book',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RatingRow extends StatelessWidget {
  const _RatingRow({required this.rating, required this.reviews});
  final double? rating;
  final int reviews;

  @override
  Widget build(BuildContext context) {
    final rating = this.rating;
    if (rating == null || isNewRating(reviews)) {
      return Row(
        children: [
          const Tag('NEW', color: AppColors.blue, bg: AppColors.blueSoft, icon: Icons.auto_awesome_rounded, dense: true),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              reviews == 0 ? 'No ratings yet' : '$reviews rating${reviews == 1 ? '' : 's'}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
          decoration: BoxDecoration(color: ratingColor(rating), borderRadius: BorderRadius.circular(6)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                rating.toStringAsFixed(1),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.star_rounded, color: Colors.white, size: 13),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            '${formatCount(reviews)} verified rating${reviews == 1 ? '' : 's'}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _TrainerSkeleton extends StatelessWidget {
  const _TrainerSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SkeletonBox(height: 18, width: 180),
            const SizedBox(height: 16),
            for (var i = 0; i < 3; i++) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(20)),
                child: Column(
                  children: [
                    const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(height: 116, width: 96, radius: 16),
                        SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SkeletonBox(height: 16, width: 140),
                              SizedBox(height: 10),
                              SkeletonBox(height: 12, width: 90),
                              SizedBox(height: 10),
                              SkeletonBox(height: 12),
                              SizedBox(height: 10),
                              SkeletonBox(height: 18, width: 110),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: const [
                        SkeletonBox(height: 28, width: 28),
                        SizedBox(width: 6),
                        SkeletonBox(height: 28, width: 28),
                        Spacer(),
                        SkeletonBox(height: 34, width: 120),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// My bookings
// ---------------------------------------------------------------------------

class _MyBookings extends StatelessWidget {
  const _MyBookings({required this.future, required this.onRefresh, required this.onFind, required this.onRate});
  final Future<List<TrainerBooking>> future;
  final Future<void> Function() onRefresh;
  final VoidCallback onFind;
  final ValueChanged<TrainerBooking> onRate;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: onRefresh,
      child: FutureBuilder<List<TrainerBooking>>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const SkeletonList(itemHeight: 72);
          if (snap.hasError) return _scrollable(ErrorView(error: snap.error!, onRetry: onRefresh));
          final all = snap.data!;
          if (all.isEmpty) {
            return _scrollable(
              EmptyView(
                icon: Icons.event_available_rounded,
                color: AppColors.blue,
                title: 'No sessions booked yet',
                message: 'Book a certified trainer for an online, at-home or at-gym session.',
                action: SizedBox(
                  width: 180,
                  child: AppButton(label: 'Find a trainer', height: 48, onPressed: onFind),
                ),
              ),
            );
          }
          final now = DateTime.now();
          bool upcoming(TrainerBooking b) =>
              b.status == 'confirmed' && (sessionStart(b.sessionDate, b.slotTime)?.isAfter(now) ?? false);
          final next = all.where(upcoming).toList()
            ..sort(
              (a, b) => sessionStart(a.sessionDate, a.slotTime)!.compareTo(sessionStart(b.sessionDate, b.slotTime)!),
            );
          final past = all.where((b) => !upcoming(b)).toList();

          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              if (next.isNotEmpty) ...[
                const SectionTitle('Upcoming', padding: EdgeInsets.fromLTRB(0, 20, 0, 12)),
                for (final b in next) ...[_BookingCard(booking: b, upcoming: true), const SizedBox(height: 12)],
              ],
              if (past.isNotEmpty) ...[
                const SectionTitle('Past & other', padding: EdgeInsets.fromLTRB(0, 20, 0, 12)),
                for (final b in past) ...[
                  _BookingCard(
                    booking: b,
                    upcoming: false,
                    // Verified: the session has ended and wasn't cancelled.
                    onRate:
                        b.status != 'cancelled' &&
                            (sessionStart(b.sessionDate, b.slotTime)?.add(const Duration(minutes: 60)).isBefore(now) ??
                                false)
                        ? () => onRate(b)
                        : null,
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _scrollable(Widget child) => LayoutBuilder(
    builder: (context, c) => SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: c.maxHeight),
        child: child,
      ),
    ),
  );
}

class _BookingCard extends StatelessWidget {
  const _BookingCard({required this.booking, required this.upcoming, this.onRate});
  final TrainerBooking booking;
  final bool upcoming;
  final VoidCallback? onRate;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final mode = TrainerMode.of(b.mode);
    final date = DateTime.tryParse(b.sessionDate);
    final (String label, Color color) = switch (b.status) {
      'confirmed' => upcoming ? ('UPCOMING', AppColors.green) : ('CONFIRMED', AppColors.blue),
      'completed' => ('COMPLETED', AppColors.blue),
      'cancelled' => ('CANCELLED', AppColors.red),
      _ => (b.status.toUpperCase(), AppColors.text2),
    };

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(width: 56, height: 56, child: NetImage(b.photoUrl, fallback: AppImages.homeWorkout, radius: 14)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.trainerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(mode.icon, size: 15, color: mode.color),
                        const SizedBox(width: 4),
                        Text(
                          mode.label,
                          style: TextStyle(fontSize: 12.5, color: mode.color, fontWeight: FontWeight.w700),
                        ),
                        const Text(
                          '  ·  60 min',
                          style: TextStyle(fontSize: 12.5, color: AppColors.text3, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Tag(label, color: color, dense: true),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                const Icon(Icons.calendar_today_rounded, size: 15, color: AppColors.text2),
                const SizedBox(width: 6),
                Text(
                  date == null ? b.sessionDate : formatDayDate(date),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 14),
                const Icon(Icons.schedule_rounded, size: 15, color: AppColors.text2),
                const SizedBox(width: 6),
                Text(b.slotTime, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(formatPaise(b.amountPaise), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
          if (onRate != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onRate,
                icon: const Icon(Icons.star_rounded, size: 18, color: AppColors.amber),
                label: const Text('Rate this session'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Icon for a BRD §6 trainer group key.
IconData trainerGroupIcon(String key) => switch (key) {
  'gym_strength' => Icons.fitness_center_rounded,
  'yoga_mind' => Icons.self_improvement_rounded,
  'dance_group' => Icons.music_note_rounded,
  'martial_arts' => Icons.sports_mma_rounded,
  'sports' => Icons.sports_tennis_rounded,
  'health_recovery' => Icons.healing_rounded,
  'nutrition' => Icons.restaurant_rounded,
  'special' => Icons.diversity_3_rounded,
  _ => Icons.bolt_rounded,
};

class _FilterPill extends StatelessWidget {
  const _FilterPill({required this.icon, required this.label, required this.on, required this.onTap, this.dropdown = false});
  final IconData icon;
  final String label;
  final bool on;
  final bool dropdown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: on ? AppColors.primarySoft : AppColors.surface,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: on ? AppColors.primary : AppColors.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: on ? AppColors.primary : AppColors.amber),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: on ? AppColors.primary : AppColors.text),
            ),
            if (dropdown) Icon(Icons.keyboard_arrow_down_rounded, size: 17, color: on ? AppColors.primary : AppColors.text2),
            if (on && !dropdown) ...[
              const SizedBox(width: 3),
              const Icon(Icons.close_rounded, size: 14, color: AppColors.primary),
            ],
          ],
        ),
      ),
    );
  }
}
