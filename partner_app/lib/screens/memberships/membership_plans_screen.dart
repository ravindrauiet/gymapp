import 'package:fitkey_core/fitkey_core.dart' show formatPaise, formatShortDate;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/memberships_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../bookings/paid_via.dart';
import 'members_screen.dart';
import 'plan_form_screen.dart';

/// A centre's own membership plans: approval status, on/off, offers, edit and archive.
class MembershipPlansScreen extends StatefulWidget {
  const MembershipPlansScreen({super.key, required this.venueId, required this.venueName});

  final String venueId;
  final String venueName;

  @override
  State<MembershipPlansScreen> createState() => _MembershipPlansScreenState();
}

class _MembershipPlansScreenState extends State<MembershipPlansScreen> {
  late Future<PlanList> _future = _load();
  final _busy = <String>{};

  Future<PlanList> _load() => context.read<PartnerSession>().api.centrePlans(widget.venueId);

  Future<void> _reload() async {
    if (!mounted) return;
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // Shown by the error state.
    }
  }

  Future<void> _openForm(double commissionPct, [CentrePlan? plan]) async {
    final saved = await push<bool>(
      context,
      PlanFormScreen(venueId: widget.venueId, venueName: widget.venueName, commissionPct: commissionPct, existing: plan),
    );
    if (saved == true) await _reload();
  }

  Future<void> _run(CentrePlan p, Future<void> Function() action, String done) async {
    setState(() => _busy.add(p.id));
    try {
      await action();
      if (!mounted) return;
      toast(context, done);
      await _reload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
    }
  }

  Future<void> _toggle(CentrePlan p, bool on) {
    final api = context.read<PartnerSession>().api;
    return _run(p, () => api.setCentrePlanActive(p.id, on),
        on ? (p.approvalStatus == 'approved' ? '${p.name} is on sale again' : '${p.name} will go on sale once approved') : '${p.name} paused — hidden from members');
  }

  Future<void> _offer(CentrePlan p) async {
    final pct = await showAppSheet<int>(context, builder: (_) => _OfferSheet(plan: p));
    if (pct == null || pct == p.offerPct || !mounted) return;
    final api = context.read<PartnerSession>().api;
    await _run(p, () => api.setCentrePlanOffer(p.id, pct), pct == 0 ? 'Offer removed' : '$pct% off is live on ${p.name}');
  }

  Future<void> _archive(CentrePlan p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Archive ${p.name}?'),
        content: Text(p.activeMembers > 0
            ? 'It will be removed from sale. The ${p.activeMembers} member${p.activeMembers == 1 ? '' : 's'} who already bought it keep their membership until it ends.'
            : 'It will be removed from sale. Members who already bought it keep their membership until it ends.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Archive', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = context.read<PartnerSession>().api;
    await _run(p, () => api.archiveCentrePlan(p.id), '${p.name} archived');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PlanList>(
      future: _future,
      builder: (context, snap) {
        final commission = snap.data?.commissionPct ?? 15;
        return Scaffold(
          appBar: AppBar(
            title: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Membership plans'),
              Text(widget.venueName,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
            ]),
            actions: [
              IconButton(
                tooltip: 'Members',
                icon: const Icon(Icons.groups_rounded),
                onPressed: () => push<void>(context, MembersScreen(venueId: widget.venueId, venueName: widget.venueName)),
              ),
            ],
          ),
          bottomNavigationBar: snap.hasData
              ? BottomActionBar(
                  child: AppButton(label: 'Create a plan', icon: Icons.add_rounded, onPressed: () => _openForm(commission)),
                )
              : null,
          body: _body(snap, commission),
        );
      },
    );
  }

  Widget _body(AsyncSnapshot<PlanList> snap, double commission) {
    if (snap.connectionState != ConnectionState.done && !snap.hasData) return const SkeletonList(count: 3, itemHeight: 120);
    if (snap.hasError) return RefreshFill(onRefresh: _reload, child: ErrorView(error: snap.error!, onRetry: _reload));
    final plans = snap.data!.plans;
    final pct = _pct(commission);
    if (plans.isEmpty) {
      return RefreshFill(
        onRefresh: _reload,
        child: EmptyView(
          icon: Icons.card_membership_rounded,
          title: 'Sell your own memberships',
          message:
              'Create day passes, monthly, quarterly or annual plans for ${widget.venueName}. FitKey reviews each plan before members can buy it. FitKey keeps $pct of each sale.',
          action: SizedBox(
            width: 200,
            child: AppButton(label: 'Create a plan', height: 48, onPressed: () => _openForm(commission)),
          ),
        ),
      );
    }
    final live = plans.where((p) => p.isLive).length;
    final pending = plans.where((p) => p.approvalStatus == 'pending').length;
    final active = plans.fold<int>(0, (s, p) => s + p.activeMembers);
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          AppCard(
            child: Row(children: [
              Expanded(child: MiniStat(value: '$live', label: 'Live plans', color: AppColors.green)),
              Expanded(child: MiniStat(value: '$pending', label: 'In review', color: AppColors.amber)),
              Expanded(child: MiniStat(value: '$active', label: 'Active members', color: AppColors.blue)),
            ]),
          ),
          const SizedBox(height: 12),
          NoteStrip(
            icon: Icons.verified_user_outlined,
            text: 'New plans and edits go to FitKey for review before members see them. Switching a plan on/off and '
                'changing its offer apply instantly. FitKey keeps $pct of each sale · memberships are non-refundable.',
          ),
          const SizedBox(height: 16),
          for (final p in plans)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _PlanCard(
                plan: p,
                busy: _busy.contains(p.id),
                onToggle: (on) => _toggle(p, on),
                onEdit: () => _openForm(commission, p),
                onOffer: () => _offer(p),
                onArchive: () => _archive(p),
              ),
            ),
        ],
      ),
    );
  }

  static String _pct(double v) => '${v % 1 == 0 ? v.toInt() : v.toStringAsFixed(1)}%';
}

// ---------------------------------------------------------------------------

class ApprovalPill extends StatelessWidget {
  const ApprovalPill(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) => switch (status) {
        'approved' => const Tag('APPROVED', icon: Icons.verified_rounded, color: AppColors.green, dense: true),
        'rejected' => const Tag('CHANGES NEEDED', icon: Icons.error_outline_rounded, color: AppColors.red, dense: true),
        _ => const Tag('IN REVIEW', icon: Icons.hourglass_top_rounded, color: AppColors.amber, dense: true),
      };
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.busy,
    required this.onToggle,
    required this.onEdit,
    required this.onOffer,
    required this.onArchive,
  });

  final CentrePlan plan;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onOffer;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    final p = plan;
    final limits = [
      if (p.maxVisitsPerDay != null) '${p.maxVisitsPerDay}/day',
      if (p.maxVisitsPerWeek != null) '${p.maxVisitsPerWeek}/week',
    ];
    final String statusLine;
    final Color statusColor;
    if (p.approvalStatus == 'rejected') {
      statusLine = 'Not visible to members — update the plan and resubmit';
      statusColor = AppColors.red;
    } else if (p.approvalStatus == 'pending') {
      statusLine = p.isActive ? 'Goes on sale as soon as FitKey approves it' : 'In review · switched off';
      statusColor = AppColors.amber;
    } else if (p.isActive) {
      statusLine = 'On sale to members';
      statusColor = AppColors.green;
    } else {
      statusLine = 'Paused — hidden from members';
      statusColor = AppColors.text3;
    }

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconBubble(Icons.card_membership_rounded, color: p.isLive ? AppColors.primary : AppColors.text3, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: -0.2)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  ApprovalPill(p.approvalStatus),
                  Tag(durationLabel(p.duration), color: AppColors.blue, dense: true),
                  if (p.offerPct > 0) Tag('${p.offerPct}% OFF', color: AppColors.primary, solid: true, dense: true),
                ]),
              ]),
            ),
            busy
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2)),
                  )
                : Switch(value: p.isActive, onChanged: onToggle),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            PriceText(
              price: formatPaise(p.effectivePricePaise),
              mrp: p.offerPct > 0 ? formatPaise(p.pricePaise) : null,
              size: 20,
            ),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text('/ ${p.durationDays} day${p.durationDays == 1 ? '' : 's'}',
                  style: const TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
        if (p.description != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(p.description!,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2, fontSize: 13)),
          ),
        if (p.inclusions.isNotEmpty || limits.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final i in p.inclusions)
                Tag(i, icon: Icons.check_rounded, color: AppColors.text2, bg: AppColors.surfaceAlt, dense: true),
              if (limits.isNotEmpty)
                Tag('Max ${limits.join(' · ')}', icon: Icons.event_repeat_rounded, color: AppColors.purple, dense: true),
            ]),
          ),
        if (p.approvalStatus == 'rejected' && p.reviewNote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: NoteStrip(icon: Icons.feedback_outlined, color: AppColors.red, text: 'FitKey review: ${p.reviewNote!}'),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            Icon(Icons.circle, size: 8, color: statusColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(statusLine, style: TextStyle(color: statusColor, fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
            Text('${p.sold} sold · ${p.activeMembers} active',
                style: const TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
        const Padding(padding: EdgeInsets.only(top: 10), child: Divider(height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(children: [
            _action(Icons.edit_rounded, 'Edit', AppColors.text, busy ? null : onEdit),
            _action(Icons.local_offer_rounded, p.offerPct > 0 ? 'Offer ${p.offerPct}%' : 'Add offer', AppColors.primary,
                busy ? null : onOffer),
            _action(Icons.archive_outlined, 'Archive', AppColors.red, busy ? null : onArchive),
          ]),
        ),
        if (p.updatedAt != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text('Updated ${formatShortDate(p.updatedAt!)}',
                style: const TextStyle(color: AppColors.text3, fontSize: 11)),
          ),
      ]),
    );
  }

  Widget _action(IconData icon, String label, Color color, VoidCallback? onTap) => Expanded(
        child: TextButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 18, color: onTap == null ? AppColors.text3 : color),
          label: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: onTap == null ? AppColors.text3 : color, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
      );
}

// ---------------------------------------------------------------------------

class _OfferSheet extends StatefulWidget {
  const _OfferSheet({required this.plan});
  final CentrePlan plan;

  @override
  State<_OfferSheet> createState() => _OfferSheetState();
}

class _OfferSheetState extends State<_OfferSheet> {
  late int _pct = widget.plan.offerPct;
  static const _quick = [0, 10, 15, 20, 25, 30, 50];

  @override
  Widget build(BuildContext context) {
    final p = widget.plan;
    final price = priceAfterOffer(p.pricePaise, _pct);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Offer on this plan', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${p.name} · ${durationLabel(p.duration)}', style: const TextStyle(color: AppColors.text2)),
          const SizedBox(height: 18),
          AppCard(
            border: true,
            shadow: false,
            color: AppColors.bg,
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Members pay', style: TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  PriceText(price: formatPaise(price), mrp: _pct > 0 ? formatPaise(p.pricePaise) : null, size: 26),
                ]),
              ),
              if (_pct > 0) Tag('$_pct% OFF', color: AppColors.primary, solid: true),
            ]),
          ),
          const SizedBox(height: 14),
          Slider(
            value: _pct.toDouble(),
            min: 0,
            max: 90,
            divisions: 90,
            label: '$_pct%',
            onChanged: (v) => setState(() => _pct = v.round()),
          ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final q in _quick)
              ChoiceChip(
                label: Text(q == 0 ? 'No offer' : '$q%'),
                selected: _pct == q,
                onSelected: (_) => setState(() => _pct = q),
              ),
          ]),
          const SizedBox(height: 12),
          const Text('Offers apply instantly — no FitKey re-review needed. Members who already bought keep their price.',
              style: TextStyle(color: AppColors.text3, fontSize: 12)),
          const SizedBox(height: 16),
          AppButton(
            label: _pct == 0 ? 'Remove offer' : 'Apply $_pct% off',
            icon: Icons.local_offer_rounded,
            onPressed: () => Navigator.pop(context, _pct),
          ),
        ]),
      ),
    );
  }
}
