import 'dart:typed_data';

import 'package:fitkey_core/fitkey_core.dart' show formatDate, formatPaise, formatShortDate;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams, XFile;

import '../../data/rse_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';

Color payoutStatusColor(String s) => switch (s) {
  'paid' => AppColors.green,
  'failed' => AppColors.red,
  'processing' => AppColors.blue,
  _ => AppColors.amber,
};

String payoutStatusLabel(String s) => switch (s) {
  'paid' => 'Paid',
  'failed' => 'Failed',
  'processing' => 'Processing',
  'pending' => 'Pending',
  _ => s.isEmpty ? 'Pending' : '${s[0].toUpperCase()}${s.substring(1)}',
};

/// Downloads an authenticated file with the API token and hands it to the share sheet (save / send / open).
/// The browser can't carry our bearer token, so the bytes go through the API client.
Future<void> downloadAndShare(
  BuildContext context, {
  required String path,
  required String filename,
  required String mime,
}) async {
  toast(context, 'Preparing $filename…', icon: Icons.download_rounded);
  try {
    final bytes = await context.read<PartnerSession>().api.downloadBytes(path);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(Uint8List.fromList(bytes), mimeType: mime, name: filename)],
        fileNameOverrides: [filename],
        subject: filename,
      ),
    );
  } catch (e) {
    if (context.mounted) toast(context, friendlyError(e), error: true);
  }
}

/// Payouts (BRD §10.3): schedule, each payout's status / UTR, CSV statement and GST invoice.
/// [invoices] = the "GST invoices" view of the same list.
class PayoutsScreen extends StatefulWidget {
  const PayoutsScreen({super.key, this.invoices = false});
  final bool invoices;

  @override
  State<PayoutsScreen> createState() => _PayoutsScreenState();
}

class _PayoutsScreenState extends State<PayoutsScreen> {
  late Future<PayoutsInfo> _future = context.read<PartnerSession>().api.payouts();

  Future<void> _reload() async {
    final f = context.read<PartnerSession>().api.payouts();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {}
  }

  String _period(Payout p) => p.periodStart == null || p.periodEnd == null
      ? 'Payout'
      : '${formatShortDate(p.periodStart!)} – ${formatShortDate(p.periodEnd!)}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.invoices ? 'GST invoices' : 'Payouts')),
      body: FutureBuilder<PayoutsInfo>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 4, itemHeight: 110);
          if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
          final info = snap.data!;
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                if (!widget.invoices)
                  AppCard(
                    child: Row(
                      children: [
                        const IconBubble(Icons.event_repeat_rounded, color: AppColors.green, size: 44),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Paid ${info.schedule}',
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                              ),
                              Text(
                                info.nextPayoutOn == null
                                    ? 'To your verified bank account'
                                    : 'Next payout on ${formatDate(info.nextPayoutOn!)}',
                                style: const TextStyle(color: AppColors.text2),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  const Text(
                    'FitKey issues a GST invoice for the commission on each payout. Download it for your books.',
                    style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600),
                  ),
                const SizedBox(height: 14),
                if (info.payouts.isEmpty)
                  const EmptyView(
                    icon: Icons.account_balance_rounded,
                    title: 'No payouts yet',
                    message: 'Your first payout appears here after your first FitKey earnings.',
                  )
                else
                  for (final p in info.payouts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: AppCard(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _period(p),
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                                  ),
                                ),
                                Tag(payoutStatusLabel(p.status), color: payoutStatusColor(p.status), dense: true),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (!widget.invoices) ...[
                              Text(
                                'Gross ${formatPaise(p.grossPaise)} · commission ${formatPaise(p.commissionPaise)}'
                                '${p.gstPaise > 0 ? ' · GST ${formatPaise(p.gstPaise)}' : ''}',
                                style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                              ),
                              const SizedBox(height: 4),
                            ],
                            Row(
                              children: [
                                Text(
                                  formatPaise(p.netPaise),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 20,
                                    color: AppColors.green,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    [
                                      if (p.paidAt != null) 'paid ${formatShortDate(p.paidAt!)}',
                                      if (p.utr != null) 'UTR ${p.utr}',
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: AppColors.text3, fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: [
                                if (!widget.invoices)
                                  OutlinedButton.icon(
                                    onPressed: () => downloadAndShare(
                                      context,
                                      path: '/partner/payouts/${p.id}/statement.csv',
                                      filename: 'fitkey-statement-${p.id}.csv',
                                      mime: 'text/csv',
                                    ),
                                    icon: const Icon(Icons.table_view_rounded, size: 18),
                                    label: const Text('Statement'),
                                  ),
                                OutlinedButton.icon(
                                  onPressed: () => downloadAndShare(
                                    context,
                                    path: '/partner/payouts/${p.id}/invoice',
                                    filename: 'fitkey-gst-invoice-${p.id}.html',
                                    mime: 'text/html',
                                  ),
                                  icon: const Icon(Icons.receipt_rounded, size: 18),
                                  label: const Text('GST invoice'),
                                ),
                              ],
                            ),
                          ],
                        ),
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
