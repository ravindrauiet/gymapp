import 'package:fitkey_core/fitkey_core.dart' show apiDate, formatDate, formatPaise;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/booking_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'my_memberships_screen.dart';

/// Buy a centre's own membership: plan → start date → pay (mock) → active instantly.
class BuyMembershipScreen extends StatefulWidget {
  const BuyMembershipScreen({super.key, required this.plan, required this.venueName, this.initialStart});

  final CentrePlan plan;
  final String venueName;

  /// Renewals start the day after the current membership ends.
  final DateTime? initialStart;

  @override
  State<BuyMembershipScreen> createState() => _BuyMembershipScreenState();
}

class _BuyMembershipScreenState extends State<BuyMembershipScreen> {
  static const _maxAheadDays = 60;
  late DateTime _start = _clampStart(widget.initialStart);
  bool _agreed = false;
  bool _busy = false;

  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  DateTime _clampStart(DateTime? d) {
    final t = _today;
    if (d == null || d.isBefore(t)) return t;
    final max = t.add(const Duration(days: _maxAheadDays));
    return d.isAfter(max) ? max : d;
  }

  DateTime get _end => _start.add(Duration(days: widget.plan.durationDays - 1));

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: _today,
      lastDate: _today.add(const Duration(days: _maxAheadDays)),
      helpText: 'Membership starts on',
    );
    if (d != null && mounted) setState(() => _start = d);
  }

  Future<void> _pay() async {
    setState(() => _busy = true);
    try {
      final m = await context.read<Session>().api.buyMembership(widget.plan.id, startDate: apiDate(_start));
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const IconBubble(Icons.check_rounded, color: AppColors.green, size: 64),
          title: Text('${m.planName} is active', textAlign: TextAlign.center),
          content: Text(
            'Valid ${formatDate(parseDay(m.startsOn))} – ${formatDate(parseDay(m.endsOn))} at ${m.venueName}.\n'
            'Book slots and check in with the centre QR — free with your membership.',
            textAlign: TextAlign.center,
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Great'))],
        ),
      );
      if (!mounted) return;
      await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MyMembershipsScreen()));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.plan;
    final discounted = p.offerPct > 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Buy membership')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        AppCard(
          gradient: AppColors.passGradient,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.venueName.toUpperCase(),
                style: const TextStyle(color: AppColors.lime, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
            const SizedBox(height: 6),
            Text(p.name, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('${p.durationLabel} · ${p.validityLabel} · only at this centre',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13)),
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(formatPaise(p.effectivePricePaise),
                  style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
              if (discounted) ...[
                const SizedBox(width: 8),
                Text(formatPaise(p.pricePaise),
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6), decoration: TextDecoration.lineThrough, fontSize: 15)),
                const SizedBox(width: 8),
                Tag('${p.offerPct}% OFF', color: AppColors.ink, bg: AppColors.lime, dense: true),
              ],
            ]),
          ]),
        ),
        if (p.inclusions.isNotEmpty || p.limitsLabel != null || (p.description ?? '').isNotEmpty) ...[
          const SectionTitle("What's included"),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if ((p.description ?? '').isNotEmpty) ...[
                Text(p.description!, style: const TextStyle(color: AppColors.text2, height: 1.45)),
                const SizedBox(height: 10),
              ],
              for (final i in p.inclusions) _Bullet(Icons.check_circle_rounded, AppColors.green, i),
              if (p.limitsLabel != null) _Bullet(Icons.event_repeat_rounded, AppColors.blue, 'Slot limit: ${p.limitsLabel}'),
            ]),
          ),
        ],
        const SectionTitle('Start date'),
        AppCard(
          onTap: _pickDate,
          child: Row(children: [
            const IconBubble(Icons.calendar_month_rounded, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(formatDate(_start), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Text('Valid until ${formatDate(_end)}', style: const TextStyle(color: AppColors.text2, fontSize: 13)),
              ]),
            ),
            const Text('Change', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.amberSoft, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.info_rounded, color: AppColors.amber, size: 20),
              SizedBox(width: 8),
              Text('Non-refundable', style: TextStyle(fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 6),
            const Text(
              'Centre memberships cannot be cancelled or refunded once bought. They work only at this centre. '
              'Payments are in test mode — no money is charged yet.',
              style: TextStyle(color: AppColors.text2, height: 1.4, fontSize: 13),
            ),
            const SizedBox(height: 6),
            CheckboxListTile(
              value: _agreed,
              onChanged: (v) => setState(() => _agreed = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title: const Text('I understand this membership is non-refundable',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          ]),
        ),
      ]),
      bottomNavigationBar: BottomActionBar(
        leading: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('To pay', style: TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
          Text(formatPaise(p.effectivePricePaise), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        ]),
        child: AppButton(
          label: 'Pay & activate',
          icon: Icons.lock_rounded,
          busy: _busy,
          onPressed: _agreed ? _pay : null,
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.icon, this.color, this.text);
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35))),
      ]),
    );
  }
}
