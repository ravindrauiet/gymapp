part of 'vendor_portal_screen.dart';

/// Fulfilment pipeline, in order. `cancelled` sits outside it.
const _pipeline = ['placed', 'processing', 'dispatched', 'out_for_delivery', 'delivered'];

({String label, Color color, Color soft, IconData icon}) _statusLook(String s) => switch (s) {
      'placed' => (label: 'New', color: AppColors.primary, soft: AppColors.primarySoft, icon: Icons.fiber_new_rounded),
      'processing' => (label: 'Packing', color: AppColors.amber, soft: AppColors.amberSoft, icon: Icons.inventory_rounded),
      'dispatched' => (label: 'Shipped', color: AppColors.blue, soft: AppColors.blueSoft, icon: Icons.local_shipping_rounded),
      'out_for_delivery' =>
        (label: 'Out for delivery', color: AppColors.purple, soft: AppColors.purpleSoft, icon: Icons.delivery_dining_rounded),
      'delivered' => (label: 'Delivered', color: AppColors.green, soft: AppColors.greenSoft, icon: Icons.check_circle_rounded),
      'cancelled' => (label: 'Cancelled', color: AppColors.red, soft: AppColors.redSoft, icon: Icons.cancel_rounded),
      _ => (label: s, color: AppColors.text2, soft: AppColors.surfaceAlt, icon: Icons.receipt_long_rounded),
    };

/// The next step a seller takes for an order in [status], or null when there is nothing to do.
({String status, String label, IconData icon})? _nextAction(String status) => switch (status) {
      'placed' => (status: 'processing', label: 'Accept & start packing', icon: Icons.inventory_rounded),
      'processing' => (status: 'dispatched', label: 'Mark as shipped', icon: Icons.local_shipping_rounded),
      'dispatched' => (status: 'out_for_delivery', label: 'Out for delivery', icon: Icons.delivery_dining_rounded),
      'out_for_delivery' => (status: 'delivered', label: 'Mark delivered', icon: Icons.check_circle_rounded),
      _ => null,
    };

enum _OrderFilter { active, placed, processing, shipped, delivered, cancelled, all }

extension on _OrderFilter {
  String get label => switch (this) {
        _OrderFilter.active => 'To do',
        _OrderFilter.placed => 'New',
        _OrderFilter.processing => 'Packing',
        _OrderFilter.shipped => 'Shipped',
        _OrderFilter.delivered => 'Delivered',
        _OrderFilter.cancelled => 'Cancelled',
        _OrderFilter.all => 'All',
      };

  bool test(VendorOrderView o) => switch (this) {
        _OrderFilter.active => !const ['delivered', 'cancelled'].contains(o.status),
        _OrderFilter.placed => o.status == 'placed',
        _OrderFilter.processing => o.status == 'processing',
        _OrderFilter.shipped => o.status == 'dispatched' || o.status == 'out_for_delivery',
        _OrderFilter.delivered => o.status == 'delivered',
        _OrderFilter.cancelled => o.status == 'cancelled',
        _OrderFilter.all => true,
      };
}

class _OrdersTab extends StatefulWidget {
  const _OrdersTab({required this.future, required this.onReload});
  final Future<List<VendorOrderView>> future;
  final Future<void> Function() onReload;

  @override
  State<_OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends State<_OrdersTab> with AutomaticKeepAliveClientMixin {
  _OrderFilter _filter = _OrderFilter.active;

  /// Orders with a status update in flight.
  final _busy = <String>{};

  @override
  bool get wantKeepAlive => true;

  Future<void> _advance(VendorOrderView o, String status, {bool editTracking = false}) async {
    String? tracking;
    // Shipping asks for (or confirms) the courier tracking number.
    if (status == 'dispatched' || editTracking) {
      tracking = await showAppSheet<String>(context, builder: (_) => _TrackingSheet(order: o, shipping: !editTracking));
      if (tracking == null || !mounted) return;
    }
    setState(() => _busy.add(o.id));
    try {
      await context.read<PartnerSession>().api.updateOrderStatus(o.id, status, trackingNumber: tracking);
      if (!mounted) return;
      toast(context, editTracking ? 'Tracking number saved' : 'Order #${o.shortId} → ${_statusLook(status).label}');
      await widget.onReload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(o.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<VendorOrderView>>(
      future: widget.future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const SkeletonList(itemHeight: 220);
        if (snap.hasError) {
          return _RefreshableFill(onRefresh: widget.onReload, child: ErrorView(error: snap.error!, onRetry: widget.onReload));
        }
        final all = snap.data!;
        if (all.isEmpty) {
          return _RefreshableFill(
            onRefresh: widget.onReload,
            child: const EmptyView(
              icon: Icons.local_shipping_rounded,
              title: 'No orders yet',
              message: 'When members buy your products in the FITKEY store, orders land here for packing and shipping.',
            ),
          );
        }
        final shown = all.where(_filter.test).toList();
        return RefreshIndicator(
          onRefresh: widget.onReload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _PipelineStrip(orders: all),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: ChoiceChips<_OrderFilter>(
                  options: _OrderFilter.values,
                  selected: _filter,
                  onSelected: (f) => setState(() => _filter = f),
                  label: (f) => '${f.label} · ${all.where(f.test).length}',
                ),
              ),
              if (shown.isEmpty)
                EmptyView(
                  icon: Icons.task_alt_rounded,
                  color: AppColors.green,
                  title: _filter == _OrderFilter.active ? 'All caught up' : 'Nothing here',
                  message: _filter == _OrderFilter.active
                      ? 'Every order has been delivered or closed.'
                      : 'No orders match "${_filter.label}".',
                  action: TextButton(onPressed: () => setState(() => _filter = _OrderFilter.all), child: const Text('Show all orders')),
                )
              else
                for (final o in shown)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                    child: _OrderCard(
                      order: o,
                      busy: _busy.contains(o.id),
                      onAdvance: (s) => _advance(o, s),
                      onEditTracking: () => _advance(o, o.status, editTracking: true),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

/// Counts per pipeline stage, Swiggy-partner style.
class _PipelineStrip extends StatelessWidget {
  const _PipelineStrip({required this.orders});
  final List<VendorOrderView> orders;

  @override
  Widget build(BuildContext context) {
    final stages = _pipeline.take(4).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: AppCard(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Row(children: [
          for (var i = 0; i < stages.length; i++) ...[
            Expanded(
              child: Builder(builder: (_) {
                final look = _statusLook(stages[i]);
                final n = orders.where((o) => o.status == stages[i]).length;
                return Column(children: [
                  IconBubble(look.icon, color: look.color, bg: look.soft, size: 38, iconSize: 19),
                  const SizedBox(height: 6),
                  Text('$n', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  Text(look.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: AppColors.text2, fontWeight: FontWeight.w600)),
                ]);
              }),
            ),
            if (i < stages.length - 1) const Icon(Icons.chevron_right_rounded, color: AppColors.text3, size: 18),
          ],
        ]),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.busy, required this.onAdvance, required this.onEditTracking});
  final VendorOrderView order;
  final bool busy;
  final ValueChanged<String> onAdvance;
  final VoidCallback onEditTracking;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final look = _statusLook(o.status);
    final next = _nextAction(o.status);
    final addr = o.shippingAddress;
    final cod = o.paymentMethod == 'cod';
    final stage = _pipeline.indexOf(o.status);
    final phone = '${addr['phone'] ?? ''}';

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Order #${o.shortId}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                const SizedBox(height: 2),
                Text('${formatDateTime(o.createdAt)} · ${o.unitCount} item${o.unitCount == 1 ? '' : 's'}',
                    style: const TextStyle(color: AppColors.text3, fontSize: 12)),
              ]),
            ),
            Tag(look.label, icon: look.icon, color: look.color, bg: look.soft),
          ]),
        ),
        if (stage >= 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              for (var i = 0; i < _pipeline.length; i++) ...[
                Expanded(
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: i <= stage ? look.color : AppColors.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                if (i < _pipeline.length - 1) const SizedBox(width: 4),
              ],
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(children: [
            for (final it in o.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  Container(
                    width: 26,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(6)),
                    child: Text('${it.quantity}×', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5))),
                  Text(formatPaise(it.pricePaise * it.quantity), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                ]),
              ),
          ]),
        ),
        const Divider(height: 18, indent: 16, endIndent: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: Text(
                cod
                    ? (o.paymentStatus == 'cod_pending' ? 'Cash on delivery · collect on delivery' : 'Cash on delivery')
                    : 'Prepaid · ${o.paymentMethod.toUpperCase()}',
                style: TextStyle(color: cod ? AppColors.amber : AppColors.green, fontWeight: FontWeight.w700, fontSize: 12.5),
              ),
            ),
            const Text('Your items  ', style: TextStyle(color: AppColors.text2, fontSize: 12.5)),
            Text(formatPaise(o.vendorSubtotalPaise), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ]),
        ),
        if (addr.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.location_on_outlined, size: 18, color: AppColors.text2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  [
                    addr['fullName'],
                    addr['addressLine'],
                    [addr['city'], addr['pincode']].where((e) => e != null && '$e'.isNotEmpty).join(' – '),
                  ].where((e) => e != null && '$e'.isNotEmpty).join('\n'),
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text2, height: 1.4),
                ),
              ),
              if (phone.isNotEmpty)
                IconButton(
                  tooltip: 'Call buyer',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => launchUrl(Uri(scheme: 'tel', path: phone)),
                  icon: const Icon(Icons.call_rounded, color: AppColors.green, size: 20),
                ),
            ]),
          ),
        if (o.trackingNumber != null && o.trackingNumber!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(children: [
              const Icon(Icons.qr_code_2_rounded, size: 18, color: AppColors.text2),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Tracking ${o.trackingNumber}',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
              ),
              IconButton(
                tooltip: 'Copy',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: o.trackingNumber!));
                  toast(context, 'Tracking number copied');
                },
                icon: const Icon(Icons.copy_rounded, size: 17, color: AppColors.text2),
              ),
              if (o.status != 'delivered' && o.status != 'cancelled')
                TextButton(onPressed: busy ? null : onEditTracking, child: const Text('Edit')),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: next == null
              ? Text(
                  o.status == 'delivered' ? 'Delivered — nothing left to do.' : 'This order was cancelled by the buyer.',
                  style: const TextStyle(color: AppColors.text3, fontSize: 12.5),
                )
              : AppButton(
                  label: next.label,
                  icon: next.icon,
                  height: 46,
                  busy: busy,
                  color: _statusLook(next.status).color,
                  onPressed: () => onAdvance(next.status),
                ),
        ),
      ]),
    );
  }
}

class _TrackingSheet extends StatefulWidget {
  const _TrackingSheet({required this.order, required this.shipping});
  final VendorOrderView order;

  /// true when shipping the order (vs. only correcting the number).
  final bool shipping;

  @override
  State<_TrackingSheet> createState() => _TrackingSheetState();
}

class _TrackingSheetState extends State<_TrackingSheet> {
  late final _ctrl = TextEditingController(text: widget.order.trackingNumber ?? '');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _done() {
    final t = _ctrl.text.trim();
    if (t.length < 4) {
      toast(context, 'Enter the courier tracking number', error: true);
      return;
    }
    Navigator.pop(context, t);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.shipping ? 'Ship order #${widget.order.shortId}' : 'Tracking number',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('The buyer sees this number on their order tracking screen.',
            style: TextStyle(color: AppColors.text2, fontSize: 13)),
        const SizedBox(height: 16),
        TextField(
          controller: _ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          onSubmitted: (_) => _done(),
          decoration: const InputDecoration(
            labelText: 'Courier tracking / AWB number',
            prefixIcon: Icon(Icons.qr_code_2_rounded),
          ),
        ),
        const SizedBox(height: 18),
        AppButton(
          label: widget.shipping ? 'Mark as shipped' : 'Save tracking number',
          icon: widget.shipping ? Icons.local_shipping_rounded : null,
          onPressed: _done,
        ),
      ]),
    );
  }
}
