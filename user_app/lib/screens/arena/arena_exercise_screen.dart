import 'package:fitkey_core/fitkey_core.dart' show formatDateTime, resolveMediaUrl;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../data/arena_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'arena_camera_screen.dart';
import 'arena_visuals.dart';

/// AI Arena exercise detail: how-to, level picker, Start, leaderboards and my history.
class ArenaExerciseScreen extends StatefulWidget {
  const ArenaExerciseScreen({super.key, required this.exerciseId});
  final String exerciseId;

  @override
  State<ArenaExerciseScreen> createState() => _ArenaExerciseScreenState();
}

class _ArenaExerciseScreenState extends State<ArenaExerciseScreen> {
  late Future<ArenaExercise> _future = _load();
  Future<List<ArenaAttempt>>? _history;
  int _levelIndex = 1;
  bool _levelPicked = false;
  int _boardKey = 0; // bumps to make the leaderboard reload

  Future<ArenaExercise> _load() async {
    final api = context.read<Session>().api;
    _history = api.myArenaAttempts(exerciseId: widget.exerciseId, limit: 10);
    final e = await api.arenaExercise(widget.exerciseId);
    if (!_levelPicked) {
      // Suggest the first level above my best (or the middle one).
      final best = e.stats.myBest;
      final i = best == null ? 0 : e.levels.indexWhere((l) => l.target > best);
      _levelIndex = (i < 0 ? e.levels.length - 1 : i).clamp(0, e.levels.length - 1);
    }
    return e;
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() {
      _future = f;
      _boardKey++;
    });
    await f;
  }

  Future<void> _start(ArenaExercise e) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ArenaCameraScreen(exercise: e, level: e.levels[_levelIndex]),
    ));
    if (saved == true && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ArenaExercise>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done && !snap.hasData) {
          return Scaffold(
            backgroundColor: AppColors.bg,
            appBar: AppBar(title: const Text('AI Arena')),
            body: const SkeletonList(count: 5, itemHeight: 110),
          );
        }
        if (snap.hasError) {
          return Scaffold(
            backgroundColor: AppColors.bg,
            appBar: AppBar(title: const Text('AI Arena')),
            body: ErrorView(error: snap.error!, onRetry: _reload),
          );
        }
        final e = snap.data!;
        final v = arenaVisual(e.id);
        final level = e.levels[_levelIndex];
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _reload,
            child: CustomScrollView(slivers: [
              SliverAppBar(
                expandedHeight: 250,
                pinned: true,
                stretch: true,
                backgroundColor: AppColors.surface,
                leading: Padding(
                  padding: const EdgeInsets.all(8),
                  child: CircleAvatar(
                    backgroundColor: Colors.white,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.arrow_back_rounded, color: AppColors.ink, size: 22),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ),
                title: Text(e.name, style: const TextStyle(fontSize: 17)),
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.parallax,
                  background: Stack(fit: StackFit.expand, children: [
                    Image.asset(v.image, fit: BoxFit.cover),
                    const PhotoScrim(strength: 0.8),
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 18,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Tag('AI Arena · ${e.timed ? 'Timed hold' : 'Rep counter'}', icon: v.icon, color: Colors.white, bg: v.color),
                        const SizedBox(height: 8),
                        Text(e.name,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                        if (e.tagline != null)
                          Text(e.tagline!,
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13, height: 1.35)),
                      ]),
                    ),
                  ]),
                ),
              ),
              SliverToBoxAdapter(child: _stats(e)),
              SliverToBoxAdapter(child: _levels(e, v)),
              SliverToBoxAdapter(child: _howTo(e, v)),
              SliverToBoxAdapter(child: _Leaderboard(key: ValueKey(_boardKey), exercise: e)),
              SliverToBoxAdapter(child: _historySection(e)),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ]),
          ),
          bottomNavigationBar: BottomActionBar(
            leading: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Target', style: TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
              Text(e.format(level.target), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            ]),
            child: AppButton(label: 'Start AI count', icon: Icons.videocam_rounded, onPressed: () => _start(e)),
          ),
        );
      },
    );
  }

  Widget _stats(ArenaExercise e) {
    final s = e.stats;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(children: [
        Expanded(
          child: MetricTile(
              label: 'My best', value: s.myBest == null ? '—' : '${s.myBest}', unit: s.myBest == null ? null : (e.timed ? 's' : 'reps'),
              icon: Icons.emoji_events_rounded, color: AppColors.amber),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: MetricTile(
              label: 'India rank', value: s.myRank == null ? '—' : '#${s.myRank}', icon: Icons.flag_rounded, color: AppColors.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: MetricTile(
              label: 'This week', value: '${s.myWeekTotal}', unit: e.timed ? 's' : 'reps',
              icon: Icons.calendar_today_rounded, color: AppColors.blue),
        ),
      ]),
    );
  }

  Widget _levels(ArenaExercise e, ArenaVisual v) {
    final s = e.stats;
    final left = (e.dailyPointsCap - s.pointsToday).clamp(0, e.dailyPointsCap);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionTitle('Pick your level',
          subtitle: left > 0
              ? 'Up to $left more points available today'
              : 'Today\'s ${e.name} points are maxed — sets still count for the leaderboard'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          for (var i = 0; i < e.levels.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(child: _levelCard(e, v, i)),
          ],
        ]),
      ),
      if (s.top10Threshold != null || s.participants > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(children: [
            const Icon(Icons.local_fire_department_rounded, size: 16, color: AppColors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                s.top10Threshold == null
                    ? 'Fewer than 10 members on this board — any set gets you into the top 10!'
                    : 'Beat ${e.format(s.top10Threshold!)} in one set to enter the all-India top 10',
                style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ),
    ]);
  }

  Widget _levelCard(ArenaExercise e, ArenaVisual v, int i) {
    final l = e.levels[i];
    final on = i == _levelIndex;
    final beaten = (e.stats.myBest ?? 0) >= l.target;
    const names = ['Starter', 'Pro', 'Beast'];
    return Tap(
      onTap: () => setState(() {
        _levelIndex = i;
        _levelPicked = true;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: on ? v.soft : AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: on ? v.color : AppColors.line, width: on ? 2 : 1),
          boxShadow: on ? AppShadows.soft : null,
        ),
        child: Column(children: [
          Text(i < names.length ? names[i] : 'Level ${i + 1}',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: on ? v.color : AppColors.text3, letterSpacing: 0.4)),
          const SizedBox(height: 4),
          Text('${l.target}', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.1, letterSpacing: -0.8)),
          Text(e.timed ? 'seconds' : 'reps', style: const TextStyle(fontSize: 12, color: AppColors.text2)),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(beaten ? Icons.check_circle_rounded : Icons.stars_rounded,
                size: 14, color: beaten ? AppColors.green : AppColors.amber),
            const SizedBox(width: 3),
            Text('${l.points} pts', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
        ]),
      ),
    );
  }

  Widget _howTo(ArenaExercise e, ArenaVisual v) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionTitle('How to do it'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: AppCard(
          child: Column(children: [
            for (var i = 0; i < e.howTo.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: i == e.howTo.length - 1 ? 0 : 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: v.soft, shape: BoxShape.circle),
                    child: Text('${i + 1}', style: TextStyle(color: v.color, fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(e.howTo[i], style: const TextStyle(height: 1.4, fontSize: 13.5))),
                ]),
              ),
          ]),
        ),
      ),
      if (e.tips.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: AppCard(
            color: AppColors.amberSoft,
            shadow: false,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Icon(Icons.tips_and_updates_rounded, color: AppColors.amber, size: 20),
                SizedBox(width: 8),
                Text('Form tips', style: TextStyle(fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 8),
              for (final t in e.tips)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Icon(Icons.circle, size: 6, color: AppColors.amber),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(t, style: const TextStyle(height: 1.4, fontSize: 13, color: AppColors.text))),
                  ]),
                ),
            ]),
          ),
        ),
    ]);
  }

  Widget _historySection(ArenaExercise e) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionTitle('My sets'),
      FutureBuilder<List<ArenaAttempt>>(
        future: _history,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SkeletonList(count: 2, itemHeight: 64, padding: EdgeInsets.symmetric(horizontal: 16));
          }
          if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
          final list = snap.data!;
          if (list.isEmpty) {
            return EmptyView(
              icon: Icons.history_rounded,
              title: 'No sets yet',
              message: 'Your ${e.name.toLowerCase()} sets will appear here.',
              action: SizedBox(width: 200, child: AppButton(label: 'Start now', onPressed: () => _start(e), height: 46)),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: AppCard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(children: [
                for (var i = 0; i < list.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16, color: AppColors.line),
                  _HistoryRow(exercise: e, a: list[i]),
                ],
              ]),
            ),
          );
        },
      ),
    ]);
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.exercise, required this.a});
  final ArenaExercise exercise;
  final ArenaAttempt a;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        IconBubble(a.completed ? Icons.check_rounded : Icons.flag_outlined,
            color: a.completed ? AppColors.green : AppColors.text2,
            bg: a.completed ? AppColors.greenSoft : AppColors.surfaceAlt,
            size: 38,
            iconSize: 18),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(exercise.format(a.reps), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            Text(
              [
                formatDateTime(a.createdAt),
                if (a.level != null) a.completed ? 'level ${a.level} done' : 'level ${a.level}',
                if (a.partialReps > 0) exercise.timed ? '${a.partialReps} form breaks' : '${a.partialReps} not counted',
              ].join(' · '),
              style: const TextStyle(color: AppColors.text2, fontSize: 12),
            ),
          ]),
        ),
        if (a.clipUrl != null)
          IconButton(
            tooltip: 'Proof clip',
            icon: const Icon(Icons.play_circle_rounded, color: AppColors.primary),
            onPressed: () => showClip(context, a.clipUrl!, exercise.format(a.reps)),
          ),
        if (a.points > 0) Tag('+${a.points} pts', color: AppColors.green, bg: AppColors.greenSoft, dense: true),
      ]),
    );
  }
}

/// Leaderboards: All India / my city × best single set / this week's total.
class _Leaderboard extends StatefulWidget {
  const _Leaderboard({super.key, required this.exercise});
  final ArenaExercise exercise;

  @override
  State<_Leaderboard> createState() => _LeaderboardState();
}

class _LeaderboardState extends State<_Leaderboard> {
  String _board = 'best';
  String? _city; // null = All India
  late Future<ArenaBoard> _future = _load();

  Future<ArenaBoard> _load() =>
      context.read<Session>().api.arenaLeaderboard(widget.exercise.id, board: _board, city: _city);

  void _set({String? board, String? city, bool cityChanged = false}) {
    setState(() {
      if (board != null) _board = board;
      if (cityChanged) _city = city;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final myCity = context.watch<Session>().user?.city;
    final e = widget.exercise;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionTitle('Leaderboard',
          subtitle: _board == 'best' ? 'Most ${e.timed ? 'seconds held' : 'reps'} in one set' : 'Total ${e.timed ? 'seconds' : 'reps'} this week (Mon–Sun)'),
      ChoiceChips<String>(
        options: const ['best', 'weekly'],
        selected: _board,
        label: (b) => b == 'best' ? 'Best set' : 'This week',
        icon: (b) => b == 'best' ? Icons.emoji_events_rounded : Icons.calendar_view_week_rounded,
        onSelected: (b) => _set(board: b),
      ),
      const SizedBox(height: 8),
      ChoiceChips<String?>(
        options: [null, if (myCity != null && myCity.isNotEmpty) myCity],
        selected: _city,
        label: (c) => c ?? 'All India',
        icon: (c) => c == null ? Icons.public_rounded : Icons.location_city_rounded,
        onSelected: (c) => _set(city: c, cityChanged: true),
      ),
      const SizedBox(height: 12),
      FutureBuilder<ArenaBoard>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SkeletonList(count: 3, itemHeight: 60, padding: EdgeInsets.symmetric(horizontal: 16));
          }
          if (snap.hasError) return ErrorView(error: snap.error!, onRetry: () => _set());
          final b = snap.data!;
          if (b.entries.isEmpty) {
            return EmptyView(
              icon: Icons.leaderboard_rounded,
              title: _board == 'best' ? 'No sets yet' : 'No sets this week',
              message: _city == null ? 'Be the first name on the all-India board.' : 'Be the first in $_city.',
            );
          }
          final me = context.read<Session>().user;
          final top = b.entries.take(50).toList();
          final meInTop = b.me != null && top.any((x) => x.userId == b.me!.userId);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: AppCard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(children: [
                for (var i = 0; i < top.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16, color: AppColors.line),
                  _BoardRow(entry: top[i], exercise: e, mine: top[i].userId == b.me?.userId, board: _board, myName: me?.name),
                ],
                if (b.me != null && !meInTop) ...[
                  const Divider(height: 1, color: AppColors.line),
                  _BoardRow(entry: b.me!, exercise: e, mine: true, board: _board, myName: me?.name),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                  child: Text('${b.total} ${b.total == 1 ? 'member' : 'members'} on this board',
                      style: const TextStyle(color: AppColors.text3, fontSize: 11.5)),
                ),
              ]),
            ),
          );
        },
      ),
    ]);
  }
}

class _BoardRow extends StatelessWidget {
  const _BoardRow({required this.entry, required this.exercise, required this.mine, required this.board, this.myName});
  final ArenaBoardEntry entry;
  final ArenaExercise exercise;
  final bool mine;
  final String board;
  final String? myName;

  @override
  Widget build(BuildContext context) {
    final medal = switch (entry.rank) {
      1 => const Color(0xFFF5B301),
      2 => const Color(0xFFA7AEBA),
      3 => const Color(0xFFCD7F32),
      _ => null,
    };
    final name = entry.name ?? 'FITKEY member';
    return Container(
      color: mine ? AppColors.primarySoft : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        SizedBox(
          width: 32,
          child: medal != null
              ? Icon(Icons.workspace_premium_rounded, color: medal, size: 26)
              : Text('#${entry.rank}',
                  style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.text2, fontSize: 13)),
        ),
        const SizedBox(width: 6),
        PersonAvatar(name: name, photoUrl: entry.avatarUrl, size: 38),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mine ? '$name (you)' : name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(
              [
                entry.city ?? 'India',
                if (board == 'weekly' && entry.sets != null) '${entry.sets} ${entry.sets == 1 ? 'set' : 'sets'}',
                if (board == 'best' && entry.indiaRank != null && entry.indiaRank != entry.rank) '#${entry.indiaRank} India',
              ].join(' · '),
              style: const TextStyle(color: AppColors.text2, fontSize: 12),
            ),
          ]),
        ),
        if (entry.clipUrl != null)
          IconButton(
            tooltip: 'Watch proof clip',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.play_circle_rounded, color: AppColors.primary),
            onPressed: () => showClip(context, entry.clipUrl!, '$name · ${exercise.format(entry.score)}'),
          ),
        Text(exercise.timed ? '${entry.score}s' : '${entry.score}',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: -0.3)),
      ]),
    );
  }
}

/// Plays a proof clip in a bottom sheet.
Future<void> showClip(BuildContext context, String url, String title) =>
    showAppSheet(context, builder: (_) => _ClipSheet(url: url, title: title));

class _ClipSheet extends StatefulWidget {
  const _ClipSheet({required this.url, required this.title});
  final String url;
  final String title;

  @override
  State<_ClipSheet> createState() => _ClipSheetState();
}

class _ClipSheetState extends State<_ClipSheet> {
  late final VideoPlayerController _v = VideoPlayerController.networkUrl(Uri.parse(resolveMediaUrl(widget.url)!));
  Object? _error;

  @override
  void initState() {
    super.initState();
    _v.initialize().then((_) {
      if (!mounted) return;
      _v
        ..setLooping(true)
        ..play();
      setState(() {});
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  void dispose() {
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        const Text('AI-verified proof clip', style: TextStyle(color: AppColors.text2, fontSize: 12.5)),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            color: AppColors.ink,
            height: 320,
            width: double.infinity,
            alignment: Alignment.center,
            child: _error != null
                ? const Text('This clip could not be played.', style: TextStyle(color: Colors.white))
                : !_v.value.isInitialized
                    ? const CircularProgressIndicator(color: Colors.white)
                    : AspectRatio(aspectRatio: _v.value.aspectRatio, child: VideoPlayer(_v)),
          ),
        ),
      ]),
    );
  }
}
