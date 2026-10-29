import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../ui/ui.dart';

final _coinFormat = NumberFormat.decimalPattern('en_IN');

/// 1600 → "1,600"
String formatCoins(int n) => _coinFormat.format(n);

/// The FitKey Coin mark: a gold disc with a key.
class CoinIcon extends StatelessWidget {
  const CoinIcon({super.key, this.size = 22});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFFFFD45C), Color(0xFFFFA41B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0xFFFFE9A8), width: size * 0.06),
        boxShadow: [BoxShadow(color: AppColors.amber.withValues(alpha: 0.35), blurRadius: size * 0.3, offset: Offset(0, size * 0.08))],
      ),
      child: Icon(Icons.key_rounded, size: size * 0.58, color: const Color(0xFF8A5300)),
    );
  }
}
