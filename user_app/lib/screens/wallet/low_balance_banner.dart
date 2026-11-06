import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/wallet_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../plans/plans_screen.dart';

/// BRD §3 — low balance alert for Home (and the Wallet): FitKey coins below one visit at the member's usual (else
/// cheapest) centre, or only 1 session left, with a Top up / Renew button. Renders nothing while the balance is fine,
/// while loading, on errors, and for members without a FitKey pass. The server also sends the in-app notification.
class LowBalanceBanner extends StatefulWidget {
  const LowBalanceBanner({super.key});

  @override
  State<LowBalanceBanner> createState() => _LowBalanceBannerState();
}

class _LowBalanceBannerState extends State<LowBalanceBanner> {
  LowBalance? _status;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<Session>().api.lowBalance();
      if (mounted) setState(() => _status = s);
    } catch (_) {
      // Silent: the banner is a hint, never an error surface.
    }
  }

  Future<void> _open() async {
    final s = _status;
    await push(context, PlansScreen(initialModel: s?.kind == 'sessions' ? 'sessions' : 'coins'));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    if (s == null || !s.low || _dismissed) return const SizedBox.shrink();
    final sessions = s.kind == 'sessions';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          color: AppColors.amberSoft,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.amber.withValues(alpha: 0.45)),
        ),
        child: Row(children: [
          IconBubble(sessions ? Icons.event_busy_rounded : Icons.toll_rounded, color: AppColors.amber, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.title ?? 'Low balance', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
              if (s.message != null)
                Text(s.message!, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
            ]),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _open,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.ink,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(0, 38),
            ),
            child: Text(sessions ? 'Renew' : 'Top up'),
          ),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _dismissed = true),
            icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.text3),
          ),
        ]),
      ),
    );
  }
}
