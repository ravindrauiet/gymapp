import 'package:fitkey_core/fitkey_core.dart' show formatDate, formatPaise;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/booking_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../booking/book_slot_screen.dart';
import '../booking/my_bookings_screen.dart';
import '../explore/venue_detail_screen.dart';
import '../plans/plans_screen.dart';
import 'buy_membership_screen.dart';

/// The member's FitKey pass (works at every centre) and their direct centre memberships (one centre each).
class MyMembershipsScreen extends StatefulWidget {
  const MyMembershipsScreen({super.key});

  @override
  State<MyMembershipsScreen> createState() => _MyMembershipsScreenState();
}

class _MyMembershipsScreenState extends State<MyMembershipsScreen> {
  late Future<({List<DirectMembership> memberships, FitkeyPassSummary pass})> _future = _load();
  String? _renewing;

  Future<({List<DirectMembership> memberships, FitkeyPassSummary pass})> _load() =>
      context.read<Session>().api.myMemberships();

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _future = f);
    await f.then((_) {}, onError: (_) {});
  }

  Future<void> _renew(DirectMembership m) async {
    setState(() => _renewing = m.id);
    try {
      final plans = await context.read<Session>().api.centrePlans(m.venueId);
      if (!mounted) return;
      final plan = plans.where((p) => p.id == m.planId).firstOrNull;
      setState(() => _renewing = null);
      if (plan == null) {
        toast(context, '${m.venueName} no longer offers this plan — see their current plans', error: true);
        push(context, VenueDetailScreen(venueId: m.venueId));
        return;
      }
      final end = parseDay(m.endsOn);
      await push(context, BuyMembershipScreen(plan: plan, venueName: m.venueName, initialStart: end.add(const Duration(days: 1))));
      if (mounted) _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _renewing = null);
      toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My memberships'),
        actions: [
          IconButton(
            tooltip: 'My bookings',
            icon: const Icon(Icons.event_note_rounded),
            onPressed: () => push(context, const MyBookingsScreen()),
          ),
        ],
      ),
      body: AsyncBody(
        future: _future,
        onRetry: _refresh,
        builder: (context, data) {
          final current = data.memberships.where((m) => m.state == 'active' || m.state == 'upcoming').toList();
          final past = data.memberships.where((m) => m.state == 'expired' || m.state == 'cancelled').toList();
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
              const SectionTitle('FitKey pass', subtitle: 'Works at every FitKey centre'),
              _PassCard(pass: data.pass),
              SectionTitle('Centre memberships',
                  subtitle: current.isEmpty ? null : 'Bought directly from a centre — valid only there'),
              if (current.isEmpty)
                AppCard(
                  child: Column(children: [
                    const EmptyView(
                      icon: Icons.card_membership_rounded,
                      color: AppColors.purple,
                      title: 'No centre memberships',
                      message: 'Many centres sell their own day passes and monthly plans. Open a centre to see them.',
                    ),
                  ]),
                )
              else
                for (final m in current)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _MembershipCard(
                      m: m,
                      renewing: _renewing == m.id,
                      onRenew: m.canRenew ? () => _renew(m) : null,
                    ),
                  ),
              if (past.isNotEmpty) ...[
                const SectionTitle('Expired'),
                for (final m in past)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _MembershipCard(m: m, renewing: _renewing == m.id, onRenew: m.canRenew ? () => _renew(m) : null),
                  ),
              ],
            ]),
          );
        },
      ),
    );
  }
}

class _PassCard extends StatelessWidget {
  const _PassCard({required this.pass});
  final FitkeyPassSummary pass;

  @override
  Widget build(BuildContext context) {
    final lines = <(IconData, String, String)>[
      for (final l in pass.legacy)
        (Icons.key_rounded, l.planName, '${l.state == 'upcoming' ? 'Starts ${formatDate(l.startsAt)} · ' : ''}Valid till ${formatDate(l.endsAt)}'),
      for (final s in pass.sessionPlans)
        (Icons.confirmation_number_rounded, s.name, '${s.sessionsLeft} of ${s.sessionsTotal} sessions left · till ${formatDate(s.expiresAt)}'),
      if ((pass.coinBalance ?? 0) > 0)
        (
          Icons.toll_rounded,
          '${pass.coinBalance} FitKey coins',
          pass.coinsNextExpiry == null ? 'Pay per visit' : 'Pay per visit · next expiry ${formatDate(pass.coinsNextExpiry!)}',
        ),
    ];
    return AppCard(
      gradient: AppColors.passGradient,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.key_rounded, color: AppColors.lime),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('FITKEY PASS',
                style: TextStyle(color: AppColors.lime, fontWeight: FontWeight.w800, letterSpacing: 1.4, fontSize: 12)),
          ),
          if (lines.isNotEmpty) const Tag('Active', color: AppColors.ink, bg: AppColors.lime, dense: true),
        ]),
        const SizedBox(height: 12),
        if (lines.isEmpty)
          Text('No active FitKey pass. Get one to book any FitKey centre with coins or sessions.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.8), height: 1.4))
        else
          for (final (icon, title, sub) in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                    Text(sub, style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12.5)),
                  ]),
                ),
              ]),
            ),
        const SizedBox(height: 6),
        AppButton(
          label: lines.isEmpty ? 'Get FitKey pass' : 'Renew / top up',
          icon: Icons.add_rounded,
          color: AppColors.lime,
          foreground: AppColors.ink,
          height: 46,
          onPressed: () => push(context, const PlansScreen()),
        ),
      ]),
    );
  }
}

class _MembershipCard extends StatelessWidget {
  const _MembershipCard({required this.m, required this.renewing, this.onRenew});
  final DirectMembership m;
  final bool renewing;
  final VoidCallback? onRenew;

  @override
  Widget build(BuildContext context) {
    final visual = venueVisual(m.venueCategories.isEmpty ? '' : m.venueCategories.first);
    final (label, color) = switch (m.state) {
      'active' => ('Active · ${m.daysLeft} day${m.daysLeft == 1 ? '' : 's'} left', AppColors.green),
      'upcoming' => ('Starts ${formatDate(parseDay(m.startsOn))}', AppColors.blue),
      'cancelled' => ('Cancelled', AppColors.text2),
      _ => ('Expired', AppColors.text2),
    };
    final limits = [
      if (m.maxVisitsPerDay != null) '${m.maxVisitsPerDay}/day',
      if (m.maxVisitsPerWeek != null) '${m.maxVisitsPerWeek}/week',
    ];
    final live = m.state == 'active' || m.state == 'upcoming';
    return AppCard(
      padding: const EdgeInsets.all(12),
      onTap: () => push(context, VenueDetailScreen(venueId: m.venueId)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          NetImage(m.venueCoverPhoto, fallback: visual.image, width: 68, height: 68, radius: 14),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.planName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
              Text(m.venueName,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2, fontSize: 13)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                Tag(label, color: color, dense: true),
                Tag(durationLabelOf(m.duration), color: AppColors.purple, dense: true),
              ]),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Text(
          '${formatDate(parseDay(m.startsOn))} – ${formatDate(parseDay(m.endsOn))} · paid ${formatPaise(m.amountPaise)}'
          '${limits.isEmpty ? '' : ' · limit ${limits.join(', ')}'}',
          style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
        ),
        const SizedBox(height: 10),
        Row(children: [
          if (live)
            Expanded(
              child: FilledButton.icon(
                onPressed: () => push(context, BookSlotScreen(venueId: m.venueId, venueName: m.venueName)),
                icon: const Icon(Icons.event_available_rounded, size: 18),
                label: const Text('Book slot'),
              ),
            ),
          if (live && onRenew != null) const SizedBox(width: 10),
          if (onRenew != null)
            Expanded(
              child: OutlinedButton.icon(
                onPressed: renewing ? null : onRenew,
                icon: renewing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.autorenew_rounded, size: 18),
                label: const Text('Renew'),
              ),
            ),
        ]),
      ]),
    );
  }
}
