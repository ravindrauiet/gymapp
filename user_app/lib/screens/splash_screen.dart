import 'package:flutter/material.dart';

import '../ui/ui.dart';
import '../widgets/brand.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.ink,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          BrandMark(size: 72),
          SizedBox(height: 18),
          Text('FITKEY',
              style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 6)),
          SizedBox(height: 6),
          Text('Your key to fitness, everywhere',
              style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w500)),
          SizedBox(height: 40),
          SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.lime)),
        ]),
      ),
    );
  }
}
