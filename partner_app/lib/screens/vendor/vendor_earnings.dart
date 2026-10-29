part of 'vendor_portal_screen.dart';

class _EarningsTab extends StatelessWidget {
  const _EarningsTab({required this.orders, required this.commission, required this.onReload});
  final Future<List<VendorOrderView>> orders;
  final Future<CommissionReport> commission;
  final Future<void> Function() onReload;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CommissionReport>(
      future: commission,
      builder: (context, cSnap) => FutureBuilder<List<VendorOrderView>>(
        future: orders,
        builder: (context, oSnap) {
          if (cSnap.connectionState != ConnectionState.done || oSnap.connectionState != ConnectionState.done) {
            return const _EarningsSkeleton();
          }
          final error = cSnap.error ?? oSnap.error;
          if (error != null) return _RefreshableFill(onRefresh: onReload, child: ErrorView(error: error, onRetry: onReload));
          return RefreshIndicator(
            onRefresh: onReload,
            child: _EarningsBody(report: cSnap.data!, orders: oSnap.data!),
          );
        },
      ),
    );
  }
}

class _EarningsBody extends StatelessWidget {
  const _EarningsBody({required this.report, required this.orders});
  final CommissionReport report;
  final List<VendorOrderView> orders;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final valid = orders.where((o) => o.status != 'cancelled').toList();
    final delivered = valid.where((o) => o.status == 'delivered').fold<int>(0, (s, o) => s + o.vendorSubtotalPaise);
    final inTransit = valid.where((o) => o.status != 'delivered').fold<int>(0, (s, o) => s + o.vendorSubtotalPaise);
    final aov = r.ordersCount == 0 ? 0 : r.grossRevenuePaise ~/ r.ordersCount;

    // Last 14 days of this seller's sales (cancelled orders excluded).
    final today = DateUtils.dateOnly(DateTime.now());
    final days = List.generate(14, (i) => today.subtract(Duration(days: 13 - i)));
    final byDay = <String, int>{for (final d in days) apiDate(d): 0};
    for (final o in valid) {
      final k = apiDate(o.createdAt);
      if (byDay.containsKey(k)) byDay[k] = byDay[k]! + o.vendorSubtotalPaise;
    }
    final fortnight = byDay.values.fold<int>(0, (a, b) => a + b);

    // Best sellers by revenue.
    final perProduct = <String, ({int units, int paise})>{};
    for (final o in valid) {
      for (final it in o.items) {
        final cur = perProduct[it.title] ?? (units: 0, paise: 0);
        perProduct[it.title] = (units: cur.units + it.quantity, paise: cur.paise + it.pricePaise * it.quantity);
      }
    }
    final top = perProduct.entries.toList()..sort((a, b) => b.value.paise.compareTo(a.value.paise));

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        // Intentional dark hero, like the member app's pass card.
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(gradient: AppColors.passGradient, borderRadius: BorderRadius.circular(22), boxShadow: AppShadows.card),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('NET PAYOUT', style: TextStyle(color: AppColors.lime, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
            const SizedBox(height: 6),
            Text(formatPaise(r.netPayoutPaise),
                style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
            const SizedBox(height: 4),
            Text(
              'After the ${_pct(r.commissionRatePercent)} FITKEY commission on ${formatPaise(r.grossRevenuePaise)} of sales',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: Row(children: [
                  Expanded(
                    flex: r.netPayoutPaise <= 0 && r.commissionPaise <= 0 ? 1 : r.netPayoutPaise,
                    child: Container(color: AppColors.lime),
                  ),
                  if (r.commissionPaise > 0) Expanded(flex: r.commissionPaise, child: Container(color: AppColors.primary)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              _legend(AppColors.lime, 'You ${formatPaise(r.netPayoutPaise)}'),
              const SizedBox(width: 14),
              _legend(AppColors.primary, 'Fee ${formatPaise(r.commissionPaise)}'),
            ]),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: MetricTile(label: 'Gross sales', value: formatPaise(r.grossRevenuePaise), icon: Icons.payments_rounded, color: AppColors.green)),
          const SizedBox(width: 10),
          Expanded(child: MetricTile(label: 'Orders', value: '${r.ordersCount}', icon: Icons.receipt_long_rounded, color: AppColors.blue)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: MetricTile(label: 'Avg order value', value: formatPaise(aov), icon: Icons.shopping_bag_rounded, color: AppColors.purple)),
          const SizedBox(width: 10),
          Expanded(
            child: MetricTile(
              label: 'FITKEY fee (${_pct(r.commissionRatePercent)})',
              value: formatPaise(r.commissionPaise),
              icon: Icons.percent_rounded,
              color: AppColors.primary,
            ),
          ),
        ]),
        const SectionTitle('Sales · last 14 days', padding: EdgeInsets.fromLTRB(0, 26, 0, 12)),
        AppCard(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text.rich(TextSpan(children: [
                TextSpan(text: formatPaise(fortnight), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const TextSpan(text: '  your items, excl. cancelled', style: TextStyle(color: AppColors.text2, fontSize: 12)),
              ])),
            ),
            SizedBox(height: 170, child: _SalesChart(days: days, values: byDay.values.toList())),
          ]),
        ),
        const SectionTitle('Where your money is', padding: EdgeInsets.fromLTRB(0, 26, 0, 12)),
        AppCard(
          child: Column(children: [
            _row(Icons.check_circle_rounded, AppColors.green, 'Delivered orders', formatPaise(delivered)),
            const Divider(height: 22),
            _row(Icons.local_shipping_rounded, AppColors.blue, 'Open / in transit', formatPaise(inTransit)),
          ]),
        ),
        if (top.isNotEmpty) ...[
          const SectionTitle('Best sellers', padding: EdgeInsets.fromLTRB(0, 26, 0, 12)),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(children: [
              for (var i = 0; i < top.length && i < 5; i++) ...[
                if (i > 0) const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: i == 0 ? AppColors.amberSoft : AppColors.surfaceAlt, shape: BoxShape.circle),
                      child: Text('${i + 1}',
                          style: TextStyle(fontWeight: FontWeight.w800, color: i == 0 ? AppColors.amber : AppColors.text2)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(top[i].key, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${top[i].value.units} sold', style: const TextStyle(color: AppColors.text3, fontSize: 12)),
                      ]),
                    ),
                    Text(formatPaise(top[i].value.paise), style: const TextStyle(fontWeight: FontWeight.w800)),
                  ]),
                ),
              ],
            ]),
          ),
        ],
        const SizedBox(height: 18),
        const Text(
          'Payouts are settled to the bank account in your Store profile. Cancelled orders are not counted.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.text3, fontSize: 12),
        ),
      ],
    );
  }

  static String _pct(double v) => '${v % 1 == 0 ? v.toInt() : v.toStringAsFixed(1)}%';

  Widget _legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(t, style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600)),
      ]);

  Widget _row(IconData i, Color c, String label, String value) => Row(children: [
        IconBubble(i, color: c, size: 36, iconSize: 18),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
      ]);
}

class _SalesChart extends StatelessWidget {
  const _SalesChart({required this.days, required this.values});
  final List<DateTime> days;
  final List<int> values;

  @override
  Widget build(BuildContext context) {
    final maxV = values.fold<int>(0, (a, b) => a > b ? a : b);
    final maxY = maxV <= 0 ? 100.0 : maxV / 100 * 1.15;
    const axis = TextStyle(color: AppColors.text3, fontSize: 10, fontWeight: FontWeight.w600);
    return BarChart(BarChartData(
      maxY: maxY,
      alignment: BarChartAlignment.spaceAround,
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => AppColors.ink,
          tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          getTooltipItem: (group, _, _, _) => BarTooltipItem(
            '${formatDayDate(days[group.x])}\n',
            const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
            children: [
              TextSpan(
                text: formatPaise(values[group.x]),
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ),
      titlesData: FlTitlesData(
        leftTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        topTitles: const AxisTitles(),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            getTitlesWidget: (v, _) {
              final i = v.toInt();
              if (i < 0 || i >= days.length || (i % 2 != 1 && i != days.length - 1)) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(i == days.length - 1 ? 'Today' : formatShortDate(days[i]), style: axis),
              );
            },
          ),
        ),
      ),
      barGroups: [
        for (var i = 0; i < values.length; i++)
          BarChartGroupData(x: i, barRods: [
            BarChartRodData(
              toY: values[i] / 100,
              width: 12,
              color: values[i] <= 0 ? AppColors.surfaceAlt : AppColors.primary,
              borderRadius: BorderRadius.circular(6),
              backDrawRodData: BackgroundBarChartRodData(show: true, toY: maxY, color: AppColors.bg),
            ),
          ]),
      ],
    ));
  }
}

class _EarningsSkeleton extends StatelessWidget {
  const _EarningsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: const [
          SkeletonBox(height: 170, radius: 22),
          SizedBox(height: 14),
          Row(children: [
            Expanded(child: SkeletonBox(height: 104, radius: 20)),
            SizedBox(width: 10),
            Expanded(child: SkeletonBox(height: 104, radius: 20)),
          ]),
          SizedBox(height: 28),
          SkeletonBox(height: 18, width: 160),
          SizedBox(height: 12),
          SkeletonBox(height: 210, radius: 20),
        ],
      ),
    );
  }
}
