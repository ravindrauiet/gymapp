import 'package:flutter/material.dart';

import '../../ui/ui.dart';
import 'arena_tab.dart';

/// ProveIt as a full screen (first Home grid entry). The same content is the ProveIt tab in Community.
class ProveItScreen extends StatelessWidget {
  const ProveItScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        titleSpacing: 0,
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('ProveIt', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 19)),
          Text('Only real reps count', style: TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
      body: const SafeArea(top: false, child: ArenaTab()),
    );
  }
}
