import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../../widgets/venue_card.dart';
import 'venue_detail_screen.dart';

/// U3 — search partner venues by category, city and name.
/// Used as the Explore tab and, with [standalone], as a pushed search screen.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key, this.standalone = false, this.initialCategory, this.autofocus = false});

  final bool standalone;
  final String? initialCategory;
  final bool autofocus;

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  String? _category;
  String? _city;
  List<String> _cities = const [];
  late Future<List<VenueSummary>> _future;

  @override
  void initState() {
    super.initState();
    final session = context.read<Session>();
    _category = widget.initialCategory;
    _city = session.user?.city;
    _future = _load();
    session.api.cities().then((c) {
      if (!mounted) return;
      setState(() => _cities = c);
      // If the member's city has no venues yet, fall back to all cities.
      if (_city != null && !c.any((x) => x.toLowerCase() == _city!.toLowerCase())) _setCity(null);
    }).catchError((_) {});
  }

  Future<List<VenueSummary>> _load() =>
      context.read<Session>().api.venues(category: _category, city: _city, q: _search.text.trim(), limit: 50);

  void _reload() => setState(() => _future = _load());

  void _setCity(String? c) {
    _city = c;
    _reload();
  }

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _reload);
  }

  Future<void> _pickCity() async {
    final picked = await showAppSheet<String>(
      context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Choose a city', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Cities where FITKEY partners are live', style: TextStyle(color: AppColors.text2)),
            const SizedBox(height: 12),
            _cityTile(ctx, null, 'All cities', Icons.public_rounded),
            for (final c in _cities) _cityTile(ctx, c, c, Icons.location_city_rounded),
          ]),
        ),
      ),
    );
    if (picked != null) _setCity(picked == '*' ? null : picked);
  }

  Widget _cityTile(BuildContext ctx, String? value, String label, IconData icon) {
    final on = (_city ?? '').toLowerCase() == (value ?? '').toLowerCase();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: IconBubble(icon, color: on ? AppColors.primary : AppColors.text2, size: 40),
      title: Text(label, style: TextStyle(fontWeight: on ? FontWeight.w800 : FontWeight.w600)),
      trailing: on ? const Icon(Icons.check_circle_rounded, color: AppColors.primary) : null,
      onTap: () => Navigator.pop(ctx, value ?? '*'),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cats = venueVisuals.toList();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: widget.standalone,
        toolbarHeight: 64,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_category == null ? 'Explore' : venueVisual(_category!).label,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          Tap(
            onTap: _cities.isEmpty ? null : _pickCity,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.location_on_rounded, size: 15, color: AppColors.primary),
              const SizedBox(width: 3),
              Text(_city ?? 'All cities',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.text2)),
              const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: AppColors.text2),
            ]),
          ),
        ]),
      ),
      body: Column(children: [
        Container(
          color: AppColors.surface,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Column(children: [
            RotatingSearchBar(
              hints: const ["'gym name'", "'area or locality'", "'swimming'", "'yoga studio'"],
              controller: _search,
              autofocus: widget.autofocus,
              onChanged: _onSearch,
              onSubmitted: (_) => _reload(),
            ),
            const SizedBox(height: 14),
            ChoiceChips<String?>(
              padding: EdgeInsets.zero,
              options: [null, ...cats.map((e) => e.key)],
              selected: _category,
              label: (c) => c == null ? 'All' : venueVisual(c).label,
              icon: (c) => c == null ? Icons.apps_rounded : venueVisual(c).icon,
              onSelected: (c) {
                _category = c;
                _reload();
              },
            ),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: () async {
              _reload();
              await _future;
            },
            child: FutureBuilder<List<VenueSummary>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const _VenueSkeleton();
                if (snap.hasError) {
                  return ListView(children: [ErrorView(error: snap.error!, onRetry: _reload)]);
                }
                final venues = snap.data!;
                if (venues.isEmpty) {
                  return ListView(children: [
                    EmptyView(
                      icon: Icons.search_off_rounded,
                      title: 'No venues found',
                      message: _search.text.isNotEmpty
                          ? 'Nothing matches "${_search.text}". Try a different name or area.'
                          : 'No ${_category == null ? '' : '${venueVisual(_category!).label.toLowerCase()} '}venues ${_city == null ? 'yet' : 'in $_city yet'}. New partners join every week!',
                      action: _category != null || _city != null || _search.text.isNotEmpty
                          ? SizedBox(
                              width: 180,
                              child: OutlinedButton(
                                onPressed: () {
                                  _search.clear();
                                  _category = null;
                                  _setCity(null);
                                },
                                child: const Text('Clear filters'),
                              ),
                            )
                          : null,
                    ),
                  ]);
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  itemCount: venues.length + 1,
                  separatorBuilder: (_, i) => SizedBox(height: i == 0 ? 12 : 16),
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return Text('${venues.length} ${venues.length == 1 ? 'venue' : 'venues'} to explore',
                          style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.text2, fontSize: 13.5));
                    }
                    final v = venues[i - 1];
                    return VenueCard(venue: v, onTap: () => push(context, VenueDetailScreen(venueId: v.id)));
                  },
                );
              },
            ),
          ),
        ),
      ]),
    );
  }
}

class _VenueSkeleton extends StatelessWidget {
  const _VenueSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          for (var i = 0; i < 3; i++) ...[
            const SkeletonBox(height: 190, radius: 22),
            const SizedBox(height: 12),
            const SkeletonBox(height: 16, width: 200),
            const SizedBox(height: 8),
            const SkeletonBox(height: 12, width: 140),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }
}
