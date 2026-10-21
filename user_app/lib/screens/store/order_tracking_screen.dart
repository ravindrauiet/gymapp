import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';

/// 2.1 Checkout & Payments: Real-time Order Tracking
class OrderTrackingScreen extends StatefulWidget {
  const OrderTrackingScreen({super.key, required this.orderId});

  final String orderId;

  @override
  State<OrderTrackingScreen> createState() => _OrderTrackingScreenState();
}

class _OrderTrackingScreenState extends State<OrderTrackingScreen> {
  late Future<({MarketplaceOrder order, List<Json> timeline})> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = context.read<Session>().api.marketplaceOrder(widget.orderId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order Tracking'),
      ),
      body: FutureBuilder<({MarketplaceOrder order, List<Json> timeline})>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ErrorState(message: errorMessage(snap.error!), onRetry: () => setState(_load));
          }

          final data = snap.data!;
          final order = data.order;
          final timeline = data.timeline;

          return RefreshIndicator(
            onRefresh: () async => setState(_load),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                // Tracking header
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: FkColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: FkColors.outline),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('Tracking ID: ${order.trackingNumber ?? 'Processing'}',
                          style: const TextStyle(fontWeight: FontWeight.w800, color: FkColors.lime, fontSize: 13)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: FkColors.lime.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          order.status.replaceAll('_', ' ').toUpperCase(),
                          style: const TextStyle(color: FkColors.lime, fontSize: 11, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text('Order ID: ${order.id}',
                        style: const TextStyle(color: FkColors.textSecondary, fontSize: 11)),
                    const SizedBox(height: 4),
                    Text('Placed on: ${formatDayDate(order.createdAt)}',
                        style: const TextStyle(color: FkColors.textSecondary, fontSize: 12)),
                  ]),
                ),
                const SizedBox(height: 20),

                // Real-time timeline
                const SectionHeader('Delivery Status'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: List.generate(timeline.length, (idx) {
                        final step = timeline[idx];
                        final completed = step['completed'] == true;
                        final isLast = idx == timeline.length - 1;
                        final label = step['label'] as String;

                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: completed ? FkColors.lime : const Color(0xFF2A2F37),
                                  ),
                                  child: Icon(
                                    completed ? Icons.check : Icons.circle,
                                    size: 14,
                                    color: completed ? Colors.black : Colors.white24,
                                  ),
                                ),
                                if (!isLast)
                                  Container(
                                    width: 2,
                                    height: 38,
                                    color: completed ? FkColors.lime : const Color(0xFF2A2F37),
                                  ),
                              ],
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 2, bottom: 20),
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    fontWeight: completed ? FontWeight.w700 : FontWeight.w400,
                                    color: completed ? Colors.white : FkColors.textSecondary,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Order Items
                const SectionHeader('Ordered SKUs'),
                ...order.items.map((it) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.inventory_2, color: FkColors.sky),
                        title: Text(it.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: Text('Qty: ${it.quantity} · ${formatInr(it.pricePaise)} each',
                            style: const TextStyle(color: FkColors.textSecondary)),
                        trailing: Text(formatInr(it.pricePaise * it.quantity),
                            style: const TextStyle(fontWeight: FontWeight.bold, color: FkColors.lime)),
                      ),
                    )),
                const SizedBox(height: 12),

                // Shipping details & total
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Shipping Address', style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(
                        '${order.shippingAddress['fullName']} (${order.shippingAddress['phone']})\n'
                        '${order.shippingAddress['addressLine']}, ${order.shippingAddress['city']} - ${order.shippingAddress['pincode']}',
                        style: const TextStyle(color: FkColors.textSecondary, fontSize: 13, height: 1.4),
                      ),
                      const Divider(height: 24),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text('Payment Method', style: TextStyle(color: FkColors.textSecondary)),
                        Text(order.paymentMethod.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                      const SizedBox(height: 6),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text('Total Amount Paid', style: TextStyle(fontWeight: FontWeight.w800)),
                        Text(formatInr(order.totalAmountPaise),
                            style: const TextStyle(color: FkColors.lime, fontWeight: FontWeight.w900, fontSize: 16)),
                      ]),
                    ]),
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
