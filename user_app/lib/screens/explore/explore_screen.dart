import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import '../../widgets/venue_card.dart';
import 'venue_detail_screen.dart';

/// U3 — search partner venues by category, city and name.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

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
    _city = session.user?.city;
    _future = _load();
    session.api.cities().then((c) {
      if (!mounted) return;
      setState(() => _cities = c);
      // If the member's city has no venues yet, fall back to all cities.
      if (_city != null && !c.any((x) => x.toLowerCase() == _city!.toLowerCase())) _setCity(null);
    }).catchError((_) {});
  }

  Future<List<VenueSummary>> _load() => context
      .read<Session>()
      .api
      .venues(category: _category, city: _city, q: _search.text.trim(), limit: 50);

  void _reload() => setState(() => _future = _load());

  void _setCity(String? c) {
    _city = c;
    _reload();
  }

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _reload);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explore'),
        actions: [
          PopupMenuButton<String?>(
            tooltip: 'City',
            initialValue: _city,
            onSelected: _setCity,
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('All cities')),
              ..._cities.map((c) => PopupMenuItem(value: c, child: Text(c))),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                const Icon(Icons.location_on, size: 18, color: FkColors.lime),
                const SizedBox(width: 4),
                Text(_city ?? 'All cities', style: const TextStyle(fontWeight: FontWeight.w600)),
                const Icon(Icons.expand_more, size: 18),
              ]),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: TextField(
              controller: _search,
              onChanged: _onSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search gyms, pools, areas…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _search.clear();
                          _reload();
                        }),
              ),
            ),
          ),
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                _chip(null, 'All', Icons.apps),
                ...venueCategories.entries.map((e) => _chip(e.key, e.value.label, e.value.icon)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                _reload();
                await _future;
              },
              child: FutureBuilder<List<VenueSummary>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) return ErrorState(message: errorMessage(snap.error!), onRetry: _reload);
                  final venues = snap.data!;
                  if (venues.isEmpty) {
                    return ListView(children: const [
                      SizedBox(height: 60),
                      EmptyState(
                        icon: Icons.search_off,
                        title: 'No venues found',
                        message: 'Try another category or city. New partners are joining every week!',
                      ),
                    ]);
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                    itemCount: venues.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (_, i) => VenueCard(
                      venue: venues[i],
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => VenueDetailScreen(venueId: venues[i].id))),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String? id, String label, IconData icon) {
    final selected = _category == id;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: selected,
        avatar: Icon(icon, size: 16, color: selected ? Colors.black : FkColors.textSecondary),
        label: Text(label, style: TextStyle(color: selected ? Colors.black : FkColors.textPrimary)),
        onSelected: (_) {
          _category = id;
          _reload();
        },
      ),
    );
  }
}
