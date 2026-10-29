import 'package:flutter/material.dart';

import '../ui/ui.dart';

/// FITKEY "F + key" monogram on the brand lime tile.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.lime,
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: [BoxShadow(color: AppColors.lime.withValues(alpha: 0.35), blurRadius: size * 0.4, offset: Offset(0, size * 0.1))],
      ),
      child: Stack(alignment: Alignment.center, children: [
        Text('F', style: TextStyle(fontSize: size * 0.6, fontWeight: FontWeight.w800, color: AppColors.ink, height: 1)),
        Positioned(right: size * 0.13, bottom: size * 0.13, child: Icon(Icons.key_rounded, size: size * 0.3, color: AppColors.ink)),
      ]),
    );
  }
}

/// Monogram + "FITKEY" wordmark + "PARTNER" tag.
class PartnerLockup extends StatelessWidget {
  const PartnerLockup({super.key, this.size = 32, this.light = false});
  final double size;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final fg = light ? Colors.white : AppColors.ink;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      BrandMark(size: size),
      SizedBox(width: size * 0.3),
      Text('FITKEY', style: TextStyle(fontSize: size * 0.55, fontWeight: FontWeight.w800, letterSpacing: size * 0.08, color: fg)),
      SizedBox(width: size * 0.22),
      Container(
        padding: EdgeInsets.symmetric(horizontal: size * 0.18, vertical: size * 0.05),
        decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(size * 0.16)),
        child: Text('PARTNER',
            style: TextStyle(fontSize: size * 0.26, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 1)),
      ),
    ]);
  }
}
