import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show Geolocator, LocationPermission;
import 'package:provider/provider.dart';

import '../../data/circles_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../trainers/trainers_screen.dart';
import 'circle_detail_screen.dart';
import 'circle_family_screen.dart';
import 'circle_forms.dart';
import 'circle_leaderboard_screen.dart';
import 'circle_scan_screen.dart';
import 'circles_common.dart';

/// Circles (BRD §3.3), shown as a tab inside Community.
class CirclesTab extends StatefulWidget {
  const CirclesTab({super.key, this.query = ''});

  /// Community search text; filter circles by name or area.
  final String query;

  @override
  State<CirclesTab> createState() => _CirclesTabState();
}

typedef _Nearby = ({String mode, String? city, List<CircleSummary> circles});

class _CirclesTabState extends State<CirclesTab> {
  List<CircleSummary>? _mine;
  _Nearby? _nearby;
  CircleBoard? _board;
  Object? _error;
  bool _locating = false;
  final _attending = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<_Nearby> _fetchNearby({bool requestLocation = false}) async {
    final api = context.read<Session>().api;
    double? lat;
    double? lng;
    if (!kIsWeb) {
      // Only ask for permission when the member taps "Use my location"; otherwise use it if already granted.
      var allowed = requestLocation;
      if (!allowed) {
        try {
          final perm = await Geolocator.checkPermission();
          allowed = perm == LocationPermission.always || perm == LocationPermission.whileInUse;
        } catch (_) {}
      }
      if (allowed) {
        final pos = await currentPosition(request: requestLocation);
        lat = pos?.latitude;
        lng = pos?.longitude;
      }
    }
    return api.nearbyCircles(lat: lat, lng: lng);
  }

  Future<void> _load() async {
    final api = context.read<Session>().api;
    try {
      final results = await Future.wait<Object?>([
        api.myCircles(),
        _fetchNearby(),
        api.circleLeaderboard().then<CircleBoard?>((b) => b, onError: (_) => null),
      ]);
      if (!mounted) return;
      setState(() {
        _mine = results[0] as List<CircleSummary>;
        _nearby = results[1] as _Nearby;
        _board = results[2] as CircleBoard?;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _useLocation() async {
    setState(() => _locating = true);
    try {
      final n = await _fetchNearby(requestLocation: true);
      if (!mounted) return;
      setState(() => _nearby = n);
      if (n.mode != 'location') toast(context, CirclesPrefs.instance.t('noLocation'), error: true);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _open(String id) async {
    await push(context, CircleDetailScreen(circleId: id));
    if (mounted) _load();
  }

  Future<void> _create() async {
    final id = await push<String>(context, const CircleFormScreen());
    if (id != null && mounted) _open(id);
  }

  Future<void> _joinCode() async {
    final id = await showJoinByCodeSheet(context);
    if (id != null && mounted) _open(id);
  }

  Future<void> _scan() async {
    final r = await scanCircleQr(context);
    if (r != null && mounted) _load();
  }

  Future<void> _attend(CircleSummary c) async {
    setState(() => _attending.add(c.id));
    final ok = await attendHere(context, c);
    if (!mounted) return;
    setState(() => _attending.remove(c.id));
    if (ok) _load();
  }

  bool _matches(CircleSummary c) {
    final q = widget.query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [c.name, c.area ?? '', c.placeName, c.city].any((s) => s.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    return CirclesShell(child: Builder(builder: (context) {
      final p = circlesOf(context);
      if (_mine == null) {
        return _error != null ? ErrorView(error: _error!, onRetry: _load) : const SkeletonList(count: 4, itemHeight: 120);
      }
      final mine = _mine!.where(_matches).toList();
      final mineIds = _mine!.map((c) => c.id).toSet();
      final nearby = (_nearby?.circles ?? const <CircleSummary>[]).where((c) => !mineIds.contains(c.id) && _matches(c)).toList();
      final searching = widget.query.trim().isNotEmpty;

      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
          Row(children: [
            Expanded(
              child: Text(p.t('circles'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: -0.4)),
            ),
            const CirclesA11yToggles(),
          ]),
          const SizedBox(height: 12),
          if (_mine!.isEmpty && !searching) ...[
            PhotoBanner(
              image: AppImages.yoga,
              eyebrow: p.t('heroEyebrow'),
              title: p.t('heroTitle'),
              subtitle: p.t('heroSub'),
              cta: p.t('create'),
              onTap: _create,
            ),
            const SizedBox(height: 14),
          ],
          _quickActions(p),
          if (mine.isNotEmpty) ...[
            SectionTitle(p.t('myCircles'), padding: const EdgeInsets.fromLTRB(0, 22, 0, 10)),
            for (final c in mine) _MyCircleCard(circle: c, busy: _attending.contains(c.id), onOpen: () => _open(c.id), onAttend: () => _attend(c)),
          ],
          if (!searching && _board != null && (_board!.entries.isNotEmpty || _board!.circleOfTheMonth != null)) ...[
            SectionTitle(
              p.t('leaderboard'),
              subtitle: '${p.t('leaderboardSub')}${_board!.city == null ? '' : ' · ${_board!.city}'}',
              action: p.t('seeAll'),
              onAction: () => push(context, CircleLeaderboardScreen(city: _board!.city)),
              padding: const EdgeInsets.fromLTRB(0, 22, 0, 10),
            ),
            if (_board!.circleOfTheMonth != null) ...[
              CircleOfMonthCard(entry: _board!.circleOfTheMonth!),
              const SizedBox(height: 10),
            ],
            if (_board!.entries.isNotEmpty)
              AppCard(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(children: [for (final e in _board!.entries.take(3)) CircleBoardRow(entry: e)]),
              ),
          ],
          SectionTitle(
            p.t('nearMe'),
            subtitle: switch (_nearby?.mode) {
              'location' => p.t('nearMeSubLoc'),
              'city' => p.t('nearMeSubCity', {'city': _nearby?.city}),
              _ => p.t('nearMeSubAll'),
            },
            padding: const EdgeInsets.fromLTRB(0, 22, 0, 10),
          ),
          if (!kIsWeb && _nearby?.mode != 'location')
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: OutlinedButton.icon(
                onPressed: _locating ? null : _useLocation,
                icon: _locating
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.my_location_rounded),
                label: Text(p.t('pinUse')),
              ),
            ),
          if (nearby.isEmpty)
            EmptyView(
              icon: Icons.park_rounded,
              color: AppColors.green,
              title: searching ? p.t('noMatch', {'q': widget.query.trim()}) : p.t('noNearby'),
              message: searching ? null : p.t('noNearbyMsg'),
              action: SizedBox(
                width: 220,
                child: AppButton(label: p.t('create'), icon: Icons.add_rounded, onPressed: _create, height: 48),
              ),
            ),
          for (final c in nearby) _NearbyCard(circle: c, onOpen: () => _open(c.id)),
          const SizedBox(height: 18),
          PhotoBanner(
            image: AppImages.groupClass,
            eyebrow: 'FITKEY',
            title: p.t('bookTrainer'),
            subtitle: p.t('bookTrainerSub'),
            cta: p.t('seeAll'),
            height: 150,
            onTap: () => push(context, const TrainersScreen()),
          ),
        ]),
      );
    }));
  }

  Widget _quickActions(CirclesPrefs p) {
    Widget action(IconData icon, Color color, String label, VoidCallback onTap) => Expanded(
          child: Tap(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                boxShadow: AppShadows.soft,
              ),
              child: Column(children: [
                IconBubble(icon, color: color, size: 46),
                const SizedBox(height: 8),
                Text(label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, height: 1.2)),
              ]),
            ),
          ),
        );
    return Row(children: [
      action(Icons.add_circle_rounded, AppColors.primary, p.t('create'), _create),
      const SizedBox(width: 8),
      action(Icons.key_rounded, AppColors.blue, p.t('joinCode'), _joinCode),
      const SizedBox(width: 8),
      action(Icons.qr_code_scanner_rounded, AppColors.ink, p.t('scanQr'), _scan),
      const SizedBox(width: 8),
      action(Icons.family_restroom_rounded, AppColors.teal, p.t('family'), () => push(context, const CircleFamilyScreen())),
    ]);
  }
}

class _MyCircleCard extends StatelessWidget {
  const _MyCircleCard({required this.circle, required this.busy, required this.onOpen, required this.onAttend});
  final CircleSummary circle;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onAttend;

  @override
  Widget build(BuildContext context) {
    final p = circlesOf(context);
    final c = circle;
    final v = circleVisual(c.activity);
    final next = c.nextSession;
    final open = next != null && next.isOpen; // 'open' only ever applies to today's session
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        onTap: onOpen,
        padding: EdgeInsets.zero,
        child: Column(children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: SizedBox(
              height: 110,
              child: Stack(fit: StackFit.expand, children: [
                Image.asset(v.image, fit: BoxFit.cover),
                const PhotoScrim(strength: 0.8),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900)),
                        Text(scheduleLine(p, c),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.88), fontSize: 12.5)),
                      ]),
                    ),
                    if (c.isLeader) Tag(p.t('leader'), solid: true, dense: true),
                  ]),
                ),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(children: [
              Row(children: [
                const Icon(Icons.local_fire_department_rounded, color: AppColors.primary),
                const SizedBox(width: 4),
                Text(p.t('streakN', {'n': c.streak}), style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${p.t('thisMonth')} ${p.t('ofSessions', {'a': c.monthCount, 'b': c.monthSessions})}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.text2),
                  ),
                ),
              ]),
              if (next != null && !open && !c.attendedToday) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${p.t('nextSession')}: ${friendlyDate(p, next.date)}, ${clock12(next.startTime)}'
                    '${next.specialTitle != null ? ' · ${next.specialTitle}' : ''}',
                    style: const TextStyle(color: AppColors.text2, fontSize: 13),
                  ),
                ),
              ],
              if (c.attendedToday) ...[
                const SizedBox(height: 10),
                Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(16)),
                  child: Text(p.t('attended'),
                      style: const TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: 16)),
                ),
              ] else if (open) ...[
                const SizedBox(height: 10),
                AppButton(label: p.t('markAttendance'), icon: Icons.touch_app_rounded, busy: busy, onPressed: onAttend, height: 60),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _NearbyCard extends StatelessWidget {
  const _NearbyCard({required this.circle, required this.onOpen});
  final CircleSummary circle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = circlesOf(context);
    final c = circle;
    final v = circleVisual(c.activity);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        onTap: onOpen,
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.asset(v.image, width: 76, height: 76, fit: BoxFit.cover),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 2),
              Text(c.where, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
              Text(scheduleLine(p, c),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                Tag(activityLabel(p, c.activity), icon: v.icon, color: v.color, dense: true),
                Tag(p.t('members', {'n': c.headcount}), color: AppColors.teal, dense: true),
                if (c.distanceKm != null) Tag(p.t('kmAway', {'km': c.distanceKm}), color: AppColors.blue, dense: true),
              ]),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
        ]),
      ),
    );
  }
}
