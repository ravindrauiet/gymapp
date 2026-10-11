import 'package:flutter/material.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../checkin/checkin_screen.dart';
import '../community/community_screen.dart';
import '../explore/explore_screen.dart';
import '../profile/profile_screen.dart';
import '../studio/studio_screen.dart';
import 'home_screen.dart';

/// Bottom navigation with a centre "Check in" action.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  static void switchTab(BuildContext context, int index) =>
      context.findAncestorStateOfType<_HomeShellState>()?._select(index);

  static const home = 0, explore = 1, studio = 2, community = 3, profile = 4;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  void _select(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [HomeScreen(), ExploreScreen(), StudioScreen(), CommunityScreen(), ProfileScreen()],
      ),
      floatingActionButton: _index == HomeShell.home || _index == HomeShell.explore
          ? FloatingActionButton.extended(
              backgroundColor: FkColors.lime,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Check in', style: TextStyle(fontWeight: FontWeight.w800)),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CheckinScreen())),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore), label: 'Explore'),
          NavigationDestination(
              icon: Icon(Icons.play_circle_outline), selectedIcon: Icon(Icons.play_circle), label: 'Studio'),
          NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Community'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Me'),
        ],
      ),
    );
  }
}
