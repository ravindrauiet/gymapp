import 'package:fitkey_core/fitkey_core.dart' show formatDayDate, formatPaise, formatTimeOfDay;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/rse_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';

/// Per-visit detail for FitKey pass users (BRD §10.3): each check-in with its gross (monthly fee ÷ 30),
/// that year's commission and the net payout, one day at a time.
class PassVisitsScreen extends StatefulWidget {
  const PassVisitsScreen({super.key, this.venueId, this.initialDate});

  final String? venueId;
  final DateTime? initialDate;

  @override
  State<PassVisitsScreen> createState() => _PassVisitsScreenState();
}

class _PassVisitsScreenState extends State<PassVisitsScreen> {
  late DateTime _day = DateUtils.dateOnly(widget.initialDate ?? DateTime.now());
  late Future<List<PassVisit>> _future = _load();

  Future<List<PassVisit>> _load() => context.read<PartnerSession>().api.passVisits(_day, venueId: widget.venueId);

  Future<void> _go(DateTime d) async {
    final today = DateUtils.dateOnly(DateTime.now());
    if (d.isAfter(today)) return;
    _day = d;
    final f = _load();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isToday = DateUtils.isSameDay(_day, DateTime.now());
    return Scaffold(
      appBar: AppBar(title: const Text('FitKey pass visits')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Previous day',
                  onPressed: () => _go(_day.subtract(const Duration(days: 1))),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: Tap(
                    onTap: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _day,
                        firstDate: DateTime(2024),
                        lastDate: DateTime.now(),
                      );
                      if (d != null) _go(d);
                    },
                    child: Text(
                      isToday ? 'Today · ${formatDayDate(_day)}' : formatDayDate(_day),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Next day',
                  onPressed: isToday ? null : () => _go(_day.add(const Duration(days: 1))),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<PassVisit>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 5, itemHeight: 72);
                if (snap.hasError) return ErrorView(error: snap.error!, onRetry: () => _go(_day));
                final visits = snap.data!;
                final net = visits.fold(0, (s, v) => s + v.netPaise);
                final commission = visits.fold(0, (s, v) => s + v.commissionPaise);
                return RefreshIndicator(
                  onRefresh: () => _go(_day),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      AppCard(
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                        child: Row(
                          children: [
                            _cell('${visits.length}', 'Visits'),
                            _cell(formatPaise(commission), 'Commission', AppColors.red),
                            _cell(formatPaise(net), 'You get', AppColors.green),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (visits.isEmpty)
                        const EmptyView(
                          icon: Icons.qr_code_2_rounded,
                          title: 'No FitKey pass visits',
                          message: 'Try another day.',
                        )
                      else
                        AppCard(
                          padding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              for (var i = 0; i < visits.length; i++) ...[
                                if (i > 0) const Divider(height: 1, color: AppColors.line),
                                _VisitRow(v: visits[i]),
                              ],
                            ],
                          ),
                        ),
                      const SizedBox(height: 12),
                      const Text(
                        'Each FitKey pass check-in pays your monthly fee ÷ 30, minus that year\'s commission. '
                        'FitKey bears the GST on pass visits.',
                        style: TextStyle(color: AppColors.text3, fontSize: 12),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _cell(String v, String l, [Color c = AppColors.text]) => Expanded(
    child: Column(
      children: [
        Text(
          v,
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c),
        ),
        Text(
          l,
          style: const TextStyle(fontSize: 11.5, color: AppColors.text2, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class _VisitRow extends StatelessWidget {
  const _VisitRow({required this.v});
  final PassVisit v;

  @override
  Widget build(BuildContext context) {
    final pct = v.commissionPct == v.commissionPct.roundToDouble()
        ? '${v.commissionPct.toInt()}'
        : '${v.commissionPct}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          PersonAvatar(name: v.memberName, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.memberName, style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(
                  '${v.time == null ? '' : '${formatTimeOfDay(v.time)} · '}${formatPaise(v.grossPaise)} − $pct% '
                  '(${formatPaise(v.commissionPaise)})',
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                ),
              ],
            ),
          ),
          Text(
            formatPaise(v.netPaise),
            style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.green),
          ),
        ],
      ),
    );
  }
}
