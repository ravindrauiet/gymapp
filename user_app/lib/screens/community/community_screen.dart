import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../ui/ui.dart';
import '../arena/arena_tab.dart';
import '../circles/circles_tab.dart';
import '../notifications/notifications_screen.dart' show NotificationBell;
import 'events_tab.dart';
import 'trophy_screen.dart';

// Public helpers other screens import from here.
export 'event_widgets.dart' show contestStyle, contestTimeLabel, contestFinished, eventStyle, EventCard, OrgBadgeChip;
export 'leaderboard_list.dart';

/// Community hub (BRD §3): Events | AI Arena | Circles, one search across all three,
/// and the overall points board behind the trophy icon.
/// Lives inside HomeShell as a bottom-nav tab, so there is no back button.
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  static const _recentKey = 'community_recent_searches';
  static const _storage = FlutterSecureStorage();

  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  bool _focused = false;
  List<String> _recent = const [];

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    try {
      final raw = await _storage.read(key: _recentKey);
      if (raw == null || !mounted) return;
      setState(() => _recent = List<String>.from(jsonDecode(raw) as List));
    } catch (_) {/* recent searches are a convenience; ignore storage errors */}
  }

  Future<void> _remember(String q) async {
    q = q.trim();
    if (q.length < 2) return;
    final next = [q, ..._recent.where((r) => r.toLowerCase() != q.toLowerCase())].take(8).toList();
    setState(() => _recent = next);
    try {
      await _storage.write(key: _recentKey, value: jsonEncode(next));
    } catch (_) {/* ignore */}
  }

  Future<void> _clearRecent() async {
    setState(() => _recent = const []);
    try {
      await _storage.delete(key: _recentKey);
    } catch (_) {/* ignore */}
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted && v.trim() != _query) setState(() => _query = v.trim());
    });
  }

  void _apply(String q) {
    _debounce?.cancel();
    _search.text = q;
    _search.selection = TextSelection.collapsed(offset: q.length);
    setState(() => _query = q.trim());
    _remember(q);
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final showRecent = _focused && _search.text.isEmpty && _recent.isNotEmpty;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: Column(children: [
          Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              boxShadow: [BoxShadow(color: Color(0x0A1A1B25), blurRadius: 12, offset: Offset(0, 4))],
            ),
            padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 14, 12, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Community', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.9, height: 1.1)),
                    SizedBox(height: 4),
                    Text('Events, AI challenges & your fitness circles',
                        style: TextStyle(fontSize: 13, color: AppColors.text2, fontWeight: FontWeight.w500)),
                  ]),
                ),
                const NotificationBell(),
                Tooltip(
                  message: 'Trophy board',
                  child: Tap(
                    onTap: () => push(context, const TrophyScreen()),
                    child: const IconBubble(Icons.emoji_events_rounded, color: AppColors.amber, size: 44),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Focus(
                  onFocusChange: (f) {
                    setState(() => _focused = f);
                    if (!f) _remember(_search.text);
                  },
                  child: RotatingSearchBar(
                    hints: const ["'50K run'", "'push-ups'", "'circles near you'", "'Indiranagar'", "'your office'"],
                    controller: _search,
                    onChanged: (v) {
                      setState(() {}); // toggles the recent-search row
                      _onChanged(v);
                    },
                    onSubmitted: _apply,
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                child: showRecent
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12, right: 4),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            const Text('RECENT SEARCHES',
                                style: TextStyle(
                                    fontSize: 11, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: AppColors.text3)),
                            const Spacer(),
                            GestureDetector(
                              onTap: _clearRecent,
                              child: const Text('Clear',
                                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.primary)),
                            ),
                          ]),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final r in _recent)
                              ActionChip(
                                avatar: const Icon(Icons.history_rounded, size: 15),
                                label: Text(r),
                                onPressed: () => _apply(r),
                              ),
                          ]),
                        ]),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 14),
              Container(
                height: 46,
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
                child: TabBar(
                  indicatorSize: TabBarIndicatorSize.tab,
                  dividerColor: Colors.transparent,
                  indicator: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(11),
                    boxShadow: AppShadows.soft,
                  ),
                  labelColor: AppColors.text,
                  unselectedLabelColor: AppColors.text2,
                  labelStyle: const TextStyle(fontFamily: kFont, fontWeight: FontWeight.w800, fontSize: 13.5),
                  unselectedLabelStyle: const TextStyle(fontFamily: kFont, fontWeight: FontWeight.w600, fontSize: 13.5),
                  labelPadding: EdgeInsets.zero,
                  splashFactory: NoSplash.splashFactory,
                  overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                  tabs: const [Tab(text: 'Events'), Tab(text: 'AI Arena'), Tab(text: 'Circles')],
                ),
              ),
            ]),
          ),
          Expanded(
            child: TabBarView(children: [
              EventsTab(query: _query, onSuggestion: _apply),
              ArenaTab(query: _query),
              CirclesTab(query: _query),
            ]),
          ),
        ]),
      ),
    );
  }
}
