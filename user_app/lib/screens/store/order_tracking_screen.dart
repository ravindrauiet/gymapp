import 'package:fitkey_core/fitkey_core.dart' show formatPaise, formatDateTime;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';

String orderStatusLabel(String status) => switch (status) {
      'placed' => 'Order placed',
      'processing' => 'Being packed',
      'dispatched' => 'Dispatched',
      'out_for_delivery' => 'Out for delivery',
      'delivered' => 'Delivered',
      'cancelled' => 'Cancelled',
      _ => status.replaceAll('_', ' '),
    };

Color orderStatusColor(String status) => switch (status) {
      'delivered' => AppColors.green,
      'cancelled' => AppColors.red,
      'dispatched' || 'out_for_delivery' => AppColors.blue,
      _ => AppColors.amber,
    };

String paymentStatusLabel(String status) => switch (status) {
      'paid' => 'Paid',
      'cod_pending' => 'Pay on delivery',
      'refunded' => 'Refunded',
      'failed' => 'Payment failed',
      _ => status.replaceAll('_', ' '),
    };

String paymentMethodLabel(String method) => switch (method) {
      'upi' => 'UPI',
      'card' => 'Credit / Debit card',
      'netbanking' => 'Netbanking',
      'cod' => 'Cash on delivery',
      _ => method.toUpperCase(),
    };

/// Live status of one marketplace order: timeline, items, address and payment.
class OrderTrackingScreen extends StatefulWidget {
  const OrderTrackingScreen({super.key, required this.orderId});

  final String orderId;

  @override
  State<OrderTrackingScreen> createState() => _OrderTrackingScreenState();
}

typedef _OrderData = ({MarketplaceOrder order, List<Json> timeline});

class _OrderTrackingScreenState extends State<OrderTrackingScreen> {
  late Future<_OrderData> _future = _fetch();

  Future<_OrderData> _fetch() => context.read<Session>().api.marketplaceOrder(widget.orderId);

  Future<void> _reload() async {
    final f = _fetch();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // Shown by the FutureBuilder.
    }
  }

  void _copy(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    toast(context, '$label copied', icon: Icons.copy_rounded);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Track order')),
      body: FutureBuilder<_OrderData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const _TrackingSkeleton();
          if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
          final order = snap.data!.order;
          final timeline = snap.data!.timeline;
          return RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _StatusHero(order: order, onCopy: _copy),
                const SectionTitle('Delivery status', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                _Timeline(steps: timeline, cancelled: order.status == 'cancelled'),
                SectionTitle('Items',
                    subtitle: '${order.items.length} product${order.items.length == 1 ? '' : 's'}',
                    padding: const EdgeInsets.fromLTRB(0, 24, 0, 12)),
                _ItemsCard(order: order),
                const SectionTitle('Delivery address', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                _AddressCard(address: order.shippingAddress),
                const SectionTitle('Payment', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                _PaymentCard(order: order),
                const SizedBox(height: 16),
                Center(
                  child: TextButton.icon(
                    onPressed: () => _copy('Order ID', order.id),
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: Text('Order ID #${order.id.substring(0, 8).toUpperCase()}'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _StatusHero extends StatelessWidget {
  const _StatusHero({required this.order, required this.onCopy});
  final MarketplaceOrder order;
  final void Function(String label, String value) onCopy;

  @override
  Widget build(BuildContext context) {
    final color = orderStatusColor(order.status);
    final icon = switch (order.status) {
      'delivered' => Icons.inventory_rounded,
      'cancelled' => Icons.cancel_rounded,
      'dispatched' || 'out_for_delivery' => Icons.local_shipping_rounded,
      _ => Icons.shopping_bag_rounded,
    };
    final message = switch (order.status) {
      'placed' => 'The seller has your order and will start packing soon.',
      'processing' => 'Your items are being packed for dispatch.',
      'dispatched' => 'Your package has left the hub and is on its way.',
      'out_for_delivery' => 'Your package will reach you today.',
      'delivered' => 'Your package was delivered. Enjoy your gear!',
      'cancelled' => 'This order was cancelled.',
      _ => 'We\'ll keep this page updated as your order moves.',
    };
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Row(children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: AppShadows.glow(color)),
              child: Icon(icon, color: Colors.white, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(orderStatusLabel(order.status),
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                const SizedBox(height: 3),
                Text(message, style: const TextStyle(fontSize: 13, color: AppColors.text2, height: 1.35)),
              ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
          child: Row(children: [
            const Icon(Icons.qr_code_rounded, size: 20, color: AppColors.text2),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Tracking number', style: TextStyle(fontSize: 12, color: AppColors.text3, fontWeight: FontWeight.w600)),
                Text(order.trackingNumber ?? 'Assigned once dispatched',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        letterSpacing: order.trackingNumber == null ? 0 : 0.6,
                        color: order.trackingNumber == null ? AppColors.text2 : AppColors.text)),
              ]),
            ),
            if (order.trackingNumber != null)
              IconButton(
                tooltip: 'Copy tracking number',
                onPressed: () => onCopy('Tracking number', order.trackingNumber!),
                icon: const Icon(Icons.copy_rounded, size: 20, color: AppColors.primary),
              ),
          ]),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
          child: Row(children: [
            const Icon(Icons.schedule_rounded, size: 18, color: AppColors.text3),
            const SizedBox(width: 10),
            Text('Placed ${formatDateTime(order.createdAt.toLocal())}',
                style: const TextStyle(fontSize: 13, color: AppColors.text2, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.steps, required this.cancelled});
  final List<Json> steps;
  final bool cancelled;

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) {
      return const AppCard(child: Text('Status updates will appear here.', style: TextStyle(color: AppColors.text2)));
    }
    // The first not-yet-completed step is "in progress".
    final current = cancelled ? -1 : steps.indexWhere((s) => s['completed'] != true);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
      child: Column(children: [
        for (final (i, s) in steps.indexed)
          _step(
            label: '${s['label'] ?? s['status'] ?? ''}',
            time: DateTime.tryParse('${s['time'] ?? ''}'),
            done: s['completed'] == true,
            active: i == current,
            nextDone: i + 1 < steps.length && steps[i + 1]['completed'] == true,
            last: i == steps.length - 1,
          ),
      ]),
    );
  }

  Widget _step({
    required String label,
    required DateTime? time,
    required bool done,
    required bool active,
    required bool nextDone,
    required bool last,
  }) {
    final dotColor = done ? AppColors.green : (active ? AppColors.amber : AppColors.line);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 28,
          child: Column(children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? AppColors.green : AppColors.surface,
                border: Border.all(color: dotColor, width: done ? 0 : 2.4),
              ),
              child: done
                  ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                  : active
                      ? Center(
                          child: Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(color: AppColors.amber, shape: BoxShape.circle)))
                      : null,
            ),
            if (!last)
              Expanded(
                child: Container(
                  width: 2.4,
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  decoration: BoxDecoration(
                    color: done && nextDone ? AppColors.green : AppColors.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: 2, bottom: last ? 14 : 22),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: done || active ? FontWeight.w800 : FontWeight.w600,
                      color: done || active ? AppColors.text : AppColors.text3)),
              if (done && time != null) ...[
                const SizedBox(height: 2),
                Text(formatDateTime(time.toLocal()), style: const TextStyle(fontSize: 12, color: AppColors.text2)),
              ] else if (active) ...[
                const SizedBox(height: 2),
                const Text('In progress', style: TextStyle(fontSize: 12, color: AppColors.amber, fontWeight: FontWeight.w700)),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}

class _ItemsCard extends StatelessWidget {
  const _ItemsCard({required this.order});
  final MarketplaceOrder order;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Column(children: [
        for (final (i, it) in order.items.indexed) ...[
          if (i > 0) const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(children: [
              const IconBubble(Icons.inventory_2_rounded, color: AppColors.primary, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(it.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, height: 1.3)),
                  const SizedBox(height: 3),
                  Text('${it.quantity} × ${formatPaise(it.pricePaise)}',
                      style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
                ]),
              ),
              const SizedBox(width: 8),
              Text(formatPaise(it.pricePaise * it.quantity), style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.address});
  final Json address;

  @override
  Widget build(BuildContext context) {
    String f(String k) => '${address[k] ?? ''}'.trim();
    final line2 = [f('city'), f('pincode')].where((s) => s.isNotEmpty).join(' – ');
    return AppCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const IconBubble(Icons.location_on_rounded, color: AppColors.primary, size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(f('fullName').isEmpty ? 'Recipient' : f('fullName'),
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
            const SizedBox(height: 4),
            if (f('addressLine').isNotEmpty)
              Text(f('addressLine'), style: const TextStyle(color: AppColors.text2, height: 1.4)),
            if (line2.isNotEmpty) Text(line2, style: const TextStyle(color: AppColors.text2, height: 1.4)),
            if (f('phone').isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.phone_rounded, size: 15, color: AppColors.text3),
                const SizedBox(width: 6),
                Text(f('phone'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }
}

class _PaymentCard extends StatelessWidget {
  const _PaymentCard({required this.order});
  final MarketplaceOrder order;

  @override
  Widget build(BuildContext context) {
    final paid = order.paymentStatus == 'paid';
    final itemsTotal = order.items.fold<int>(0, (s, i) => s + i.pricePaise * i.quantity);
    return AppCard(
      child: Column(children: [
        Row(children: [
          IconBubble(order.paymentMethod == 'cod' ? Icons.payments_rounded : Icons.account_balance_wallet_rounded,
              color: AppColors.blue, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Text(paymentMethodLabel(order.paymentMethod),
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
          ),
          Tag(paymentStatusLabel(order.paymentStatus).toUpperCase(),
              color: paid ? AppColors.green : AppColors.amber, icon: paid ? Icons.check_circle_rounded : Icons.schedule_rounded),
        ]),
        const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Divider()),
        if (order.items.isNotEmpty && itemsTotal != order.totalAmountPaise)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              const Text('Item total', style: TextStyle(color: AppColors.text2)),
              const Spacer(),
              Text(formatPaise(itemsTotal), style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          ),
        Row(children: [
          Text(paid ? 'Amount paid' : 'Amount to pay', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const Spacer(),
          Text(formatPaise(order.totalAmountPaise), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        ]),
      ]),
    );
  }
}

class _TrackingSkeleton extends StatelessWidget {
  const _TrackingSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: const [
          SkeletonBox(height: 190, radius: 20),
          SizedBox(height: 28),
          SkeletonBox(height: 18, width: 140),
          SizedBox(height: 14),
          SkeletonBox(height: 250, radius: 20),
          SizedBox(height: 28),
          SkeletonBox(height: 18, width: 100),
          SizedBox(height: 14),
          SkeletonBox(height: 120, radius: 20),
        ],
      ),
    );
  }
}
