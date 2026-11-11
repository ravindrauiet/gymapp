import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/brd_api.dart';
import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../account/account_tab.dart';
import '../earn/earn_tab.dart';
import '../run/run_tab.dart';
import '../sell/sell_tab.dart';
import 'home_tab.dart';
import 'shell.dart';

export 'venue_card.dart' show VenueCard;

/// Signed-in shell (BRD §9): Home · Run · Sell · Earn · Account. Earn is hidden while a FitKey employee lists on
/// behalf of a partner (the server refuses earnings to staff tokens).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  ShellTab _tab = ShellTab.home;
  final _visited = <ShellTab>{ShellTab.home};
  late Future<List<VenueListItem>> _venues = _load();
  String? _userId;

  Future<List<VenueListItem>> _load() => context.read<PartnerSession>().api.venues();

  /// Acting as a partner / back to the employee swaps the user: start again from Home with fresh data.
  void _syncUser(String? id) {
    if (_userId != null && id != null && id != _userId) {
      _tab = ShellTab.home;
      _visited
        ..clear()
        ..add(ShellTab.home);
      _venues = _load();
    }
    _userId = id;
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() => _venues = f);
    try {
      await f;
    } catch (_) {
      // Shown by the tab's error state.
    }
  }

  Future<void> _open(Widget screen) async {
    await push<void>(context, screen);
    if (mounted) _reload();
  }

  void _goTab(ShellTab t) => setState(() {
    _tab = t;
    _visited.add(t);
  });

  static const _dest = {
    ShellTab.home: NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home_rounded),
      label: 'Home',
    ),
    ShellTab.run: NavigationDestination(
      icon: Icon(Icons.directions_run_rounded),
      selectedIcon: Icon(Icons.directions_run_rounded),
      label: 'Run',
    ),
    ShellTab.sell: NavigationDestination(
      icon: Icon(Icons.storefront_outlined),
      selectedIcon: Icon(Icons.storefront_rounded),
      label: 'Sell',
    ),
    ShellTab.earn: NavigationDestination(
      icon: Icon(Icons.account_balance_wallet_outlined),
      selectedIcon: Icon(Icons.account_balance_wallet_rounded),
      label: 'Earn',
    ),
    ShellTab.account: NavigationDestination(
      icon: Icon(Icons.person_outline_rounded),
      selectedIcon: Icon(Icons.person_rounded),
      label: 'Account',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PartnerSession>();
    _syncUser(session.user?.id);
    final acting = session.isActingAsPartner;
    final type = PartnerType.parse(session.user?.partnerType) ?? PartnerType.fitnessCentre;
    final tabs = [
      for (final t in ShellTab.values)
        if (!(acting && t == ShellTab.earn)) t,
    ];
    final current = tabs.contains(_tab) ? _tab : ShellTab.home;

    Widget page(ShellTab t) => switch (t) {
      ShellTab.home => const HomeTab(),
      ShellTab.run => const RunTab(),
      ShellTab.sell => const SellTab(),
      ShellTab.earn => const EarnTab(),
      ShellTab.account => const AccountTab(),
    };

    final body = IndexedStack(
      key: ValueKey(_userId),
      index: tabs.indexOf(current),
      children: [for (final t in tabs) _visited.contains(t) ? page(t) : const SizedBox.shrink()],
    );

    return PartnerShell(
      venues: _venues,
      reload: _reload,
      open: _open,
      goTab: _goTab,
      type: type,
      acting: acting,
      child: Scaffold(
        body: acting
            ? Column(
                children: [
                  _ActingBanner(partnerName: session.user?.name ?? session.user?.phone ?? 'partner'),
                  Expanded(
                    child: MediaQuery.removePadding(context: context, removeTop: true, child: body),
                  ),
                ],
              )
            : body,
        bottomNavigationBar: NavigationBarTheme(
          data: NavigationBarThemeData(
            backgroundColor: AppColors.surface,
            surfaceTintColor: Colors.transparent,
            indicatorColor: AppColors.primarySoft,
            height: 66,
            labelTextStyle: WidgetStateProperty.resolveWith(
              (s) => TextStyle(
                fontFamily: kFont,
                fontSize: 11.5,
                fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
                color: s.contains(WidgetState.selected) ? AppColors.text : AppColors.text2,
              ),
            ),
            iconTheme: WidgetStateProperty.resolveWith(
              (s) => IconThemeData(
                color: s.contains(WidgetState.selected) ? AppColors.primary : AppColors.text2,
                size: 24,
              ),
            ),
          ),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.line)),
            ),
            child: NavigationBar(
              selectedIndex: tabs.indexOf(current),
              onDestinationSelected: (i) => _goTab(tabs[i]),
              destinations: [for (final t in tabs) _dest[t]!],
            ),
          ),
        ),
      ),
    );
  }
}

/// Persistent banner while a FitKey employee lists on behalf of a partner (BRD §8).
class _ActingBanner extends StatefulWidget {
  const _ActingBanner({required this.partnerName});
  final String partnerName;

  @override
  State<_ActingBanner> createState() => _ActingBannerState();
}

class _ActingBannerState extends State<_ActingBanner> {
  bool _busy = false;

  Future<void> _exit() async {
    setState(() => _busy = true);
    try {
      await context.read<PartnerSession>().stopActing();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.ink,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.support_agent_rounded, color: AppColors.lime, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Listing on behalf of ${widget.partnerName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : _exit,
                style: TextButton.styleFrom(foregroundColor: AppColors.lime),
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.lime),
                      )
                    : const Text('Exit', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
