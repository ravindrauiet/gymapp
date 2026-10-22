import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/ui.dart';
import '../checkin/checkin_screen.dart';
import '../community/community_screen.dart';
import '../explore/explore_screen.dart';
import '../studio/studio_screen.dart';
import 'home_screen.dart';

/// Bottom navigation with a raised centre "Check in" scanner button.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  static void switchTab(BuildContext context, int index) =>
      context.findAncestorStateOfType<_HomeShellState>()?._select(index);

  static const home = 0, explore = 1, studio = 2, community = 3;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  final _visited = <int>{0};

  void _select(int i) {
    if (i == _index) return;
    HapticFeedback.selectionClick();
    setState(() {
      _index = i;
      _visited.add(i);
    });
  }

  @override
  Widget build(BuildContext context) {
    const pages = [HomeScreen(), ExploreScreen(), StudioScreen(), CommunityScreen()];
    return PopScope(
      canPop: _index == HomeShell.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(HomeShell.home);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          // Tabs are built the first time they're opened, then kept alive.
          children: [for (var i = 0; i < pages.length; i++) _visited.contains(i) ? pages[i] : const SizedBox.shrink()],
        ),
        bottomNavigationBar: _BottomBar(index: _index, onSelect: _select),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onSelect});
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    Widget item(int i, IconData icon, IconData active, String label) {
      final on = index == i;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onSelect(i),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              width: on ? 24 : 0,
              height: 3,
              margin: const EdgeInsets.only(bottom: 7),
              decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(2)),
            ),
            Icon(on ? active : icon, color: on ? AppColors.primary : AppColors.text3, size: 25),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                    color: on ? AppColors.text : AppColors.text3)),
          ]),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        boxShadow: [BoxShadow(color: Color(0x141A1B25), blurRadius: 24, offset: Offset(0, -6))],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 70,
          child: Row(children: [
            item(HomeShell.home, Icons.home_outlined, Icons.home_rounded, 'Home'),
            item(HomeShell.explore, Icons.explore_outlined, Icons.explore_rounded, 'Explore'),
            Expanded(
              child: Tap(
                onTap: () => push(context, const CheckinScreen()),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      shape: BoxShape.circle,
                      boxShadow: AppShadows.glow(AppColors.primary),
                    ),
                    child: const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 25),
                  ),
                  const SizedBox(height: 2),
                  const Text('Check in', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.text)),
                ]),
              ),
            ),
            item(HomeShell.studio, Icons.play_circle_outline_rounded, Icons.play_circle_rounded, 'Studio'),
            item(HomeShell.community, Icons.people_outline_rounded, Icons.people_rounded, 'Community'),
          ]),
        ),
      ),
    );
  }
}
