import 'package:fitkey_core/fitkey_core.dart'
    show formatDateTime, formatDayDate, formatPaise, formatShortDate, formatTimeOfDay, resolveMediaUrl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/rse_api.dart';
import '../../data/vendor_trainer_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';

// Run screens for the other partner types (BRD §10.4): trainer clients, store stock / low stock / returns,
// clinic appointments & patient queue, chemist orders & delivery status.

/// Shared shell: app bar + FutureBuilder + pull-to-refresh + empty state.
class _ListScreen<T> extends StatefulWidget {
  const _ListScreen({
    required this.title,
    required this.load,
    required this.itemBuilder,
    required this.empty,
    this.header,
  });

  final String title;
  final Future<List<T>> Function(BuildContext context) load;
  final Widget Function(BuildContext context, T item, Future<void> Function() reload) itemBuilder;
  final EmptyView empty;
  final Widget Function(List<T> items)? header;

  @override
  State<_ListScreen<T>> createState() => _ListScreenState<T>();
}

class _ListScreenState<T> extends State<_ListScreen<T>> {
  late Future<List<T>> _future = widget.load(context);

  Future<void> _reload() async {
    final f = widget.load(context);
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: FutureBuilder<List<T>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 5, itemHeight: 84);
          if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
          final items = snap.data!;
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                if (widget.header != null) ...[widget.header!(items), const SizedBox(height: 12)],
                if (items.isEmpty)
                  widget.empty
                else
                  for (final i in items)
                    Padding(padding: const EdgeInsets.only(bottom: 10), child: widget.itemBuilder(context, i, _reload)),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Label + colour for the statuses used by appointments, chemist orders and returns.
(String, Color) runStatusVisual(String status) => switch (status) {
  'booked' || 'requested' => (status == 'booked' ? 'Booked' : 'New', AppColors.blue),
  'checked_in' => ('Arrived', AppColors.amber),
  'accepted' || 'approved' => (status == 'approved' ? 'Approved' : 'Accepted', AppColors.amber),
  'in_consultation' => ('With doctor', AppColors.purple),
  'packed' => ('Packed', AppColors.purple),
  'out_for_delivery' => ('Out for delivery', AppColors.teal),
  'received' => ('Received', AppColors.teal),
  'completed' => ('Done', AppColors.green),
  'delivered' => ('Delivered', AppColors.green),
  'picked_up' => ('Picked up', AppColors.green),
  'refunded' => ('Refunded', AppColors.green),
  'no_show' => ('No-show', AppColors.red),
  'rejected' => ('Rejected', AppColors.red),
  'cancelled' => ('Cancelled', AppColors.red),
  _ => (status, AppColors.text2),
};

Widget _statusTag(String status) {
  final (label, color) = runStatusVisual(status);
  return Tag(label, color: color, dense: true);
}

Future<void> _act(
  BuildContext context,
  Future<void> Function() call,
  Future<void> Function() reload,
  String done,
) async {
  try {
    await call();
    if (context.mounted) toast(context, done);
    await reload();
  } catch (e) {
    if (context.mounted) toast(context, friendlyError(e), error: true);
  }
}

// ---------------------------------------------------------------------------
// Trainer: client list
// ---------------------------------------------------------------------------

class TrainerClientsScreen extends StatelessWidget {
  const TrainerClientsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _ListScreen<TrainerClientRow>(
      title: 'Clients',
      load: (ctx) => ctx.read<PartnerSession>().api.trainerClients(),
      empty: const EmptyView(
        icon: Icons.groups_rounded,
        title: 'No clients yet',
        message: 'Members who book sessions with you appear here.',
      ),
      itemBuilder: (context, c, _) => AppCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            PersonAvatar(name: c.name, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(
                    '${c.sessions} session${c.sessions == 1 ? '' : 's'} · ${c.completed} done · ${formatPaise(c.totalPaise)}',
                    style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (c.nextSessionOn != null)
                        Tag('Next ${formatShortDate(c.nextSessionOn!)}', color: AppColors.teal, dense: true),
                      if (c.lastSessionOn != null)
                        Tag('Last ${formatShortDate(c.lastSessionOn!)}', color: AppColors.text2, dense: true),
                    ],
                  ),
                ],
              ),
            ),
            if (c.phone != null && !c.phone!.contains('X'))
              IconButton(
                tooltip: 'Call',
                onPressed: () => launchUrl(Uri(scheme: 'tel', path: c.phone)),
                icon: const Icon(Icons.call_rounded, color: AppColors.green),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Store seller: stock, low stock, returns
// ---------------------------------------------------------------------------

Future<int?> _askStock(BuildContext context, String title, int current) {
  final c = TextEditingController(text: '$current');
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(labelText: 'Units in stock'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, int.tryParse(c.text)), child: const Text('Save')),
      ],
    ),
  ).whenComplete(c.dispose);
}

Widget _stockRow(
  BuildContext context, {
  required String id,
  required String title,
  required String? image,
  required String category,
  required int pricePaise,
  required int qty,
  required int threshold,
  required Future<void> Function() reload,
}) {
  final low = qty <= threshold;
  return AppCard(
    padding: const EdgeInsets.all(12),
    onTap: () async {
      final n = await _askStock(context, title, qty);
      if (n == null || !context.mounted) return;
      await _act(
        context,
        () => context.read<PartnerSession>().api.saveVendorSku(id, {'stockQuantity': n}),
        reload,
        'Stock updated',
      );
    },
    child: Row(
      children: [
        NetImage(image, fallback: productFallbackImage(category), width: 52, height: 52, radius: 12),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(
                '${formatPaise(pricePaise)} · alert at $threshold',
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '$qty',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: low ? AppColors.red : AppColors.text),
            ),
            Text(
              qty == 0 ? 'out of stock' : (low ? 'low' : 'in stock'),
              style: TextStyle(
                fontSize: 11.5,
                color: low ? AppColors.red : AppColors.text3,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class StoreStockScreen extends StatelessWidget {
  const StoreStockScreen({super.key, this.lowStockOnly = false});

  /// Default low-stock alert level when a SKU has none of its own.
  static const lowStockAt = 5;

  final bool lowStockOnly;

  @override
  Widget build(BuildContext context) {
    final empty = EmptyView(
      icon: lowStockOnly ? Icons.check_circle_rounded : Icons.inventory_2_rounded,
      color: lowStockOnly ? AppColors.green : AppColors.primary,
      title: lowStockOnly ? 'All stocked up' : 'No products yet',
      message: lowStockOnly ? 'No SKU is at or below its alert level.' : 'Add products from Sell → Products & prices.',
    );
    if (lowStockOnly) {
      return _ListScreen<LowStockProduct>(
        title: 'Low stock',
        load: (ctx) => ctx.read<PartnerSession>().api.lowStock(),
        empty: empty,
        itemBuilder: (context, p, reload) => _stockRow(
          context,
          id: p.id,
          title: p.title,
          image: p.image,
          category: p.category,
          pricePaise: p.pricePaise,
          qty: p.stockQuantity,
          threshold: p.lowStockThreshold,
          reload: reload,
        ),
      );
    }
    return _ListScreen<VendorSku>(
      title: 'Stock',
      load: (ctx) async =>
          (await ctx.read<PartnerSession>().api.vendorSkus())
            ..sort((a, b) => a.product.stockQuantity.compareTo(b.product.stockQuantity)),
      header: (items) => Text(
        '${items.where((s) => s.product.stockQuantity <= lowStockAt).length} SKUs low on stock',
        style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700),
      ),
      empty: empty,
      itemBuilder: (context, s, reload) => _stockRow(
        context,
        id: s.id,
        title: s.product.title,
        image: s.product.images.firstOrNull,
        category: s.product.category,
        pricePaise: s.product.pricePaise,
        qty: s.product.stockQuantity,
        threshold: lowStockAt,
        reload: reload,
      ),
    );
  }
}

class StoreReturnsScreen extends StatelessWidget {
  const StoreReturnsScreen({super.key});

  static const _actionLabel = {
    'approved': 'Approve',
    'rejected': 'Reject',
    'received': 'Mark received',
    'refunded': 'Mark refunded',
  };

  @override
  Widget build(BuildContext context) {
    return _ListScreen<StoreReturn>(
      title: 'Returns',
      load: (ctx) => ctx.read<PartnerSession>().api.storeReturns(),
      empty: const EmptyView(
        icon: Icons.assignment_return_rounded,
        color: AppColors.green,
        title: 'No returns',
        message: 'Return requests from members show up here.',
      ),
      itemBuilder: (context, r, reload) => AppCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${r.quantity} × ${r.title}', style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                _statusTag(r.returnStatus),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                'Order #${r.shortOrderId}',
                ?r.memberName,
                formatPaise(r.pricePaise * r.quantity),
                if (r.requestedAt != null) formatDateTime(r.requestedAt!),
              ].join(' · '),
              style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
            ),
            if (r.reason != null) ...[
              const SizedBox(height: 4),
              Text('“${r.reason}”', style: const TextStyle(color: AppColors.text3, fontSize: 12.5)),
            ],
            if (r.actions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  for (final a in r.actions)
                    a == 'rejected'
                        ? OutlinedButton(
                            onPressed: () => _act(
                              context,
                              () => context.read<PartnerSession>().api.setReturnStatus(r.itemId, a),
                              reload,
                              'Return rejected',
                            ),
                            child: Text(_actionLabel[a]!, style: const TextStyle(color: AppColors.red)),
                          )
                        : FilledButton(
                            onPressed: () => _act(
                              context,
                              () => context.read<PartnerSession>().api.setReturnStatus(r.itemId, a),
                              reload,
                              'Return updated',
                            ),
                            child: Text(_actionLabel[a]!),
                          ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Clinic: appointments & patient queue
// ---------------------------------------------------------------------------

class ClinicAppointmentsScreen extends StatelessWidget {
  const ClinicAppointmentsScreen({super.key, this.queue = false});

  /// Today's queue (GET /partner/clinic/queue): who's with the doctor, then waiting by token.
  final bool queue;

  static const _nextLabel = {'checked_in': 'Arrived', 'in_consultation': 'Call in', 'completed': 'Done'};

  @override
  Widget build(BuildContext context) {
    return _ListScreen<ClinicAppointment>(
      title: queue ? 'Patient queue' : 'Appointments',
      load: (ctx) async {
        final api = ctx.read<PartnerSession>().api;
        if (!queue) return api.clinicAppointments();
        final q = await api.clinicQueue();
        return [?q.nowServing, ...q.queue.where((a) => a.id != q.nowServing?.id)];
      },
      header: queue
          ? (items) => Text(
              '${items.where((a) => a.status == 'checked_in').length} waiting · '
              '${items.where((a) => a.status == 'booked').length} yet to arrive',
              style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w700),
            )
          : null,
      empty: EmptyView(
        icon: Icons.event_note_rounded,
        title: queue ? 'No one in the queue' : 'No upcoming appointments',
        message: queue ? 'Today\'s patients appear here in token order.' : 'Bookings from FitKey members appear here.',
      ),
      itemBuilder: (context, a, reload) {
        final next = nextAppointmentStatus(a.status);
        final serving = a.status == 'in_consultation';
        return AppCard(
          padding: const EdgeInsets.all(14),
          border: serving,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: serving ? AppColors.purpleSoft : AppColors.tealSoft,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      a.token == null ? '–' : '${a.token}',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        color: serving ? AppColors.purple : AppColors.teal,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.patientName, style: const TextStyle(fontWeight: FontWeight.w800)),
                        Text(
                          [
                            if (!queue && a.date != null) formatDayDate(a.date!),
                            if (a.time != null) formatTimeOfDay(a.time),
                            ?a.doctorName,
                            if (a.source == 'walk_in') 'walk-in',
                          ].join(' · '),
                          style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  _statusTag(a.status),
                ],
              ),
              if (a.reason != null) ...[
                const SizedBox(height: 6),
                Text(a.reason!, style: const TextStyle(color: AppColors.text3, fontSize: 12.5)),
              ],
              if (a.open) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (a.status == 'booked')
                      TextButton(
                        onPressed: () => _act(
                          context,
                          () => context.read<PartnerSession>().api.setAppointmentStatus(a.id, 'no_show'),
                          reload,
                          'Marked no-show',
                        ),
                        child: const Text('No-show', style: TextStyle(color: AppColors.red)),
                      ),
                    const Spacer(),
                    if (next != null)
                      FilledButton(
                        onPressed: () => _act(
                          context,
                          () => context.read<PartnerSession>().api.setAppointmentStatus(a.id, next),
                          reload,
                          'Updated',
                        ),
                        child: Text(_nextLabel[next]!),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Chemist: orders & delivery status
// ---------------------------------------------------------------------------

class ChemistOrdersScreen extends StatelessWidget {
  const ChemistOrdersScreen({super.key, this.deliveriesOnly = false});

  final bool deliveriesOnly;

  static const _actionLabel = {
    'accepted': 'Accept',
    'packed': 'Packed',
    'out_for_delivery': 'Send out',
    'delivered': 'Delivered',
    'picked_up': 'Picked up',
  };

  static Future<int?> _askMrp(BuildContext context) {
    final c = TextEditingController();
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Accept order'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Bill amount at MRP',
            prefixText: '₹ ',
            helperText: 'Your store discount is applied for the member',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, rupeesToPaise(c.text)), child: const Text('Accept')),
        ],
      ),
    ).whenComplete(c.dispose);
  }

  static Future<String?> _askReject(BuildContext context) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject order?'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(labelText: 'Reason (shown to the member)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Reject', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    ).whenComplete(c.dispose);
  }

  @override
  Widget build(BuildContext context) {
    return _ListScreen<ChemistOrder>(
      title: deliveriesOnly ? 'Delivery status' : 'Orders',
      load: (ctx) async {
        final list = await ctx.read<PartnerSession>().api.chemistOrders(openOnly: deliveriesOnly);
        return deliveriesOnly ? list.where((o) => o.delivery).toList() : list;
      },
      empty: EmptyView(
        icon: deliveriesOnly ? Icons.local_shipping_rounded : Icons.receipt_long_rounded,
        title: deliveriesOnly ? 'No deliveries in progress' : 'No orders yet',
        message: 'Orders from FitKey members appear here.',
      ),
      itemBuilder: (context, o, reload) {
        final next = o.nextStatus;
        final api = context.read<PartnerSession>().api;
        return AppCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(o.customerName, style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  _statusTag(o.status),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  '#${o.shortId}',
                  o.delivery ? 'Home delivery' : 'Pick-up',
                  if (o.amountPaise > 0) formatPaise(o.amountPaise),
                  if (o.createdAt != null) formatDateTime(o.createdAt!),
                ].join(' · '),
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
              ),
              const SizedBox(height: 6),
              for (final i in o.items)
                Text(
                  '${i.qty} × ${i.name}${i.note == null ? '' : ' (${i.note})'}',
                  style: const TextStyle(fontSize: 13),
                ),
              if (o.delivery && o.address != null) ...[
                const SizedBox(height: 4),
                Text(o.address!, style: const TextStyle(color: AppColors.text3, fontSize: 12.5)),
              ],
              if (o.rejectReason != null) ...[
                const SizedBox(height: 4),
                Text('Rejected: ${o.rejectReason}', style: const TextStyle(color: AppColors.red, fontSize: 12.5)),
              ],
              if (o.delivery && o.status != 'rejected' && o.status != 'cancelled') ...[
                const SizedBox(height: 10),
                _DeliverySteps(status: o.status),
              ],
              if (o.prescriptionUrl != null || next != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (o.prescriptionUrl != null)
                      TextButton.icon(
                        onPressed: () => launchUrl(Uri.parse(resolveMediaUrl(o.prescriptionUrl) ?? o.prescriptionUrl!)),
                        icon: const Icon(Icons.description_rounded),
                        label: const Text('Prescription'),
                      ),
                    const Spacer(),
                    if (o.status == 'requested')
                      TextButton(
                        onPressed: () async {
                          final reason = await _askReject(context);
                          if (reason == null || !context.mounted) return;
                          await _act(
                            context,
                            () => api.setChemistOrderStatus(
                              o.id,
                              'rejected',
                              rejectReason: reason.isEmpty ? null : reason,
                            ),
                            reload,
                            'Order rejected',
                          );
                        },
                        child: const Text('Reject', style: TextStyle(color: AppColors.red)),
                      ),
                    if (next != null)
                      FilledButton(
                        onPressed: () async {
                          int? mrp;
                          if (next == 'accepted') {
                            mrp = await _askMrp(context);
                            if (mrp == null || !context.mounted) return;
                          }
                          await _act(
                            context,
                            () => api.setChemistOrderStatus(o.id, next, mrpPaise: mrp),
                            reload,
                            'Order updated',
                          );
                        },
                        child: Text(_actionLabel[next] ?? next),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DeliverySteps extends StatelessWidget {
  const _DeliverySteps({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    const steps = ['requested', 'accepted', 'packed', 'out_for_delivery', 'delivered'];
    const labels = ['Placed', 'Accepted', 'Packed', 'On the way', 'Delivered'];
    final at = steps.indexOf(status);
    return Row(
      children: [
        for (var i = 0; i < steps.length; i++)
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 4,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: i <= at ? AppColors.teal : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  labels[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: i <= at ? AppColors.text : AppColors.text3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
