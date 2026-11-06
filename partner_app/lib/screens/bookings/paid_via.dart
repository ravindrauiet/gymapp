import 'package:flutter/material.dart';

import '../../ui/ui.dart';

/// How a visit / booking was paid, as partners see it.
class PaidViaVisual {
  const PaidViaVisual(this.label, this.long, this.icon, this.color);
  final String label;
  final String long;
  final IconData icon;
  final Color color;
}

const paidViaOrder = ['coins', 'session', 'membership', 'legacy'];

PaidViaVisual paidViaVisual(String? key) => switch (key) {
      'coins' => const PaidViaVisual('Coins', 'FitKey coins', Icons.toll_rounded, AppColors.amber),
      'session' => const PaidViaVisual('Session', 'FitKey session plan', Icons.confirmation_number_rounded, AppColors.blue),
      'membership' => const PaidViaVisual('Membership', 'Your centre membership', Icons.card_membership_rounded, AppColors.green),
      'event' => const PaidViaVisual('Event', 'Event entry', Icons.event_rounded, AppColors.pink),
      _ => const PaidViaVisual('Legacy pass', 'FitKey pass (legacy)', Icons.workspace_premium_rounded, AppColors.purple),
    };

class PaidViaTag extends StatelessWidget {
  const PaidViaTag(this.paidVia, {super.key, this.dense = true});
  final String? paidVia;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final v = paidViaVisual(paidVia);
    return Tag(v.label, icon: v.icon, color: v.color, dense: dense);
  }
}

/// "Priya S. ••4321"
String maskedMember(String name, String? last4) => last4 == null ? name : '$name  ••$last4';

/// A thin multi-colour bar splitting a total into parts (e.g. coins / session / legacy visits).
class SplitBar extends StatelessWidget {
  const SplitBar({super.key, required this.parts, this.height = 8});
  final List<({int value, Color color})> parts;
  final double height;

  @override
  Widget build(BuildContext context) {
    final shown = parts.where((p) => p.value > 0).toList();
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: shown.isEmpty
            ? Container(color: AppColors.surfaceAlt)
            : Row(children: [for (final p in shown) Expanded(flex: p.value, child: Container(color: p.color))]),
      ),
    );
  }
}

/// A scrollable wrapper so pull-to-refresh also works on empty / error states.
class RefreshFill extends StatelessWidget {
  const RefreshFill({super.key, required this.onRefresh, required this.child});
  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(constraints: BoxConstraints(minHeight: c.maxHeight), child: Center(child: child)),
        ),
      ),
    );
  }
}

/// Small "label: value" stat used inside summary cards.
class MiniStat extends StatelessWidget {
  const MiniStat({super.key, required this.value, required this.label, this.color = AppColors.text});
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color, letterSpacing: -0.4)),
      const SizedBox(height: 2),
      Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
    ]);
  }
}

/// Info strip (amber / blue soft background) for honest notes like "payments are in test mode".
class NoteStrip extends StatelessWidget {
  const NoteStrip({super.key, required this.text, this.icon = Icons.info_outline_rounded, this.color = AppColors.blue, this.bg});
  final String text;
  final IconData icon;
  final Color color;
  final Color? bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg ?? color.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(14)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 19),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(color: AppColors.text, fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.4)),
        ),
      ]),
    );
  }
}
