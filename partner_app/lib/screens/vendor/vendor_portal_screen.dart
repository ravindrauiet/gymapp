import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/partner_session.dart';

/// 2.2 Partner App Scope (FITKEY Partner Vendor Portal)
class VendorPortalScreen extends StatefulWidget {
  const VendorPortalScreen({super.key});

  @override
  State<VendorPortalScreen> createState() => _VendorPortalScreenState();
}

class _VendorPortalScreenState extends State<VendorPortalScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  late Future<VendorProfile?> _profileFuture;
  late Future<List<VendorProduct>> _productsFuture;
  late Future<List<VendorOrder>> _ordersFuture;
  late Future<CommissionReport> _commissionFuture;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadAll();
  }

  void _loadAll() {
    final api = context.read<PartnerSession>().api;
    _profileFuture = api.vendorProfile();
    _productsFuture = api.vendorProducts();
    _ordersFuture = api.vendorOrders();
    _commissionFuture = api.commissionReport();
  }

  void _reload() => setState(_loadAll);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vendor Portal (Marketplace)'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.badge_outlined), text: 'Merchant Onboarding'),
            Tab(icon: Icon(Icons.inventory_2_outlined), text: 'SKUs & Inventory'),
            Tab(icon: Icon(Icons.local_shipping_outlined), text: 'Order Fulfillment'),
            Tab(icon: Icon(Icons.monetization_on_outlined), text: 'Commission Reports'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildOnboardingTab(),
          _buildProductsTab(),
          _buildOrdersTab(),
          _buildCommissionsTab(),
        ],
      ),
    );
  }

  // ============================================================================
  // Tab 1: Merchant Onboarding & Business/Bank Details
  // ============================================================================
  Widget _buildOnboardingTab() {
    return FutureBuilder<VendorProfile?>(
      future: _profileFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        final vendor = snap.data;
        return _MerchantOnboardingForm(
          initialVendor: vendor,
          onSaved: _reload,
        );
      },
    );
  }

  // ============================================================================
  // Tab 2: SKU & Inventory Management
  // ============================================================================
  Widget _buildProductsTab() {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: FkColors.lime,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text('Add SKU', style: TextStyle(fontWeight: FontWeight.w800)),
        onPressed: () => _openAddProductDialog(context),
      ),
      body: FutureBuilder<List<VendorProduct>>(
        future: _productsFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ErrorState(message: errorMessage(snap.error!), onRetry: _reload);
          }

          final products = snap.data!;
          if (products.isEmpty) {
            return EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'No SKUs listed yet',
              message: 'List fitness supplements, apparel, wearables or gym gears for FITKEY members.',
              action: FilledButton(
                onPressed: () => _openAddProductDialog(context),
                child: const Text('Add your first SKU'),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
              itemCount: products.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, idx) {
                final p = products[idx];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            image: p.images.isNotEmpty
                                ? DecorationImage(image: NetworkImage(p.images.first), fit: BoxFit.cover)
                                : null,
                            color: const Color(0xFF252B35),
                          ),
                          child: p.images.isEmpty ? const Icon(Icons.fitness_center) : null,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(p.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                            const SizedBox(height: 2),
                            Text('${p.brand} · ${p.category.toUpperCase()}',
                                style: const TextStyle(color: FkColors.textSecondary, fontSize: 12)),
                            const SizedBox(height: 4),
                            Text(formatInr(p.pricePaise),
                                style: const TextStyle(fontWeight: FontWeight.w800, color: FkColors.lime)),
                          ]),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit, size: 20),
                          tooltip: 'Edit Stock & Price',
                          onPressed: () => _openEditProductDialog(context, p),
                        ),
                      ]),
                      const Divider(height: 20),
                      Row(children: [
                        Text('Stock: ${p.stockQuantity} units',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: p.stockQuantity < 5 ? Colors.redAccent : Colors.white,
                              fontSize: 13,
                            )),
                        const Spacer(),
                        FilledButton.tonal(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            minimumSize: Size.zero,
                          ),
                          onPressed: () => _quickAdjustStock(p),
                          child: const Text('Update Stock'),
                        ),
                      ]),
                    ]),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  // ============================================================================
  // Tab 3: Order Fulfillment
  // ============================================================================
  Widget _buildOrdersTab() {
    return FutureBuilder<List<VendorOrder>>(
      future: _ordersFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return ErrorState(message: errorMessage(snap.error!), onRetry: _reload);
        }

        final orders = snap.data!;
        if (orders.isEmpty) {
          return const EmptyState(
            icon: Icons.local_shipping_outlined,
            title: 'No incoming orders',
            message: 'Orders for your listed SKUs will appear here for fulfillment.',
          );
        }

        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: orders.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, idx) {
              final o = orders[idx];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('Order #${o.id.substring(0, 8)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: FkColors.lime.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          o.status.toUpperCase(),
                          style: const TextStyle(color: FkColors.lime, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text('Tracking: ${o.trackingNumber ?? 'Pending generation'}',
                        style: const TextStyle(color: FkColors.textSecondary, fontSize: 12)),
                    const SizedBox(height: 10),
                    ...o.items.map((it) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(children: [
                            Expanded(child: Text('${it.quantity}x ${it.title}', style: const TextStyle(fontSize: 13))),
                            Text(formatInr(it.pricePaise * it.quantity),
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                          ]),
                        )),
                    const Divider(height: 20),
                    Row(children: [
                      Expanded(
                        child: Text(
                          'Deliver to: ${o.shippingAddress['fullName']}, ${o.shippingAddress['city']}',
                          style: const TextStyle(color: FkColors.textSecondary, fontSize: 12),
                        ),
                      ),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          minimumSize: Size.zero,
                        ),
                        onPressed: () => _openFulfillDialog(context, o),
                        child: const Text('Update Status'),
                      ),
                    ]),
                  ]),
                ),
              );
            },
          ),
        );
      },
    );
  }

  // ============================================================================
  // Tab 4: Commission & Payout Reports
  // ============================================================================
  Widget _buildCommissionsTab() {
    return FutureBuilder<CommissionReport>(
      future: _commissionFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return ErrorState(message: errorMessage(snap.error!), onRetry: _reload);
        }

        final comm = snap.data!;
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Net Payout Receivable',
                        style: TextStyle(color: FkColors.textSecondary, fontSize: 13)),
                    const SizedBox(height: 6),
                    Text(formatInr(comm.netPayoutPaise),
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: FkColors.lime)),
                    const SizedBox(height: 4),
                    const Text('Processed directly to your verified bank account.',
                        style: TextStyle(color: FkColors.textSecondary, fontSize: 12)),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              const SectionHeader('Commission Summary'),
              Row(children: [
                Expanded(
                  child: StatTile(
                    label: 'Gross Sales',
                    value: formatInr(comm.grossRevenuePaise),
                    icon: Icons.point_of_sale,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'FITKEY Fee (${comm.commissionRatePercent}%)',
                    value: formatInr(comm.commissionPaise),
                    icon: Icons.pie_chart_outline,
                    color: FkColors.orange,
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: StatTile(
                    label: 'Orders Fulfilled',
                    value: '${comm.ordersCount}',
                    icon: Icons.check_circle_outline,
                    color: FkColors.sky,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'Platform Payout Rate',
                    value: '${100 - comm.commissionRatePercent.round()}%',
                    icon: Icons.account_balance,
                    color: FkColors.lime,
                  ),
                ),
              ]),
            ],
          ),
        );
      },
    );
  }

  void _quickAdjustStock(VendorProduct p) {
    int current = p.stockQuantity;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Update Stock: ${p.title}'),
          content: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
              icon: const Icon(Icons.remove_circle, size: 30),
              onPressed: () {
                if (current > 0) setDialogState(() => current--);
              },
            ),
            const SizedBox(width: 16),
            Text('$current units', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(width: 16),
            IconButton(
              icon: const Icon(Icons.add_circle, color: FkColors.lime, size: 30),
              onPressed: () => setDialogState(() => current++),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await context.read<PartnerSession>().api.updateVendorProduct(p.id, {'stockQuantity': current});
                _reload();
                if (mounted) showSnack(context, 'Stock updated to $current units');
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _openFulfillDialog(BuildContext context, VendorOrder o) {
    String status = o.status;
    final tracking = TextEditingController(text: o.trackingNumber ?? '');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Fulfill Order #${o.id.substring(0, 8)}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Fulfillment Status', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: status,
                items: const [
                  DropdownMenuItem(value: 'processing', child: Text('Processing & Packed')),
                  DropdownMenuItem(value: 'dispatched', child: Text('Dispatched')),
                  DropdownMenuItem(value: 'delivered', child: Text('Delivered')),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => status = v);
                },
              ),
              const SizedBox(height: 14),
              const Text('Tracking Number', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              TextField(
                controller: tracking,
                decoration: const InputDecoration(hintText: 'e.g. TRK12345678'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final api = context.read<PartnerSession>().api;
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(ctx);
                await api.updateOrderStatus(
                  o.id,
                  status,
                  trackingNumber: tracking.text.trim().isEmpty ? null : tracking.text.trim(),
                );
                _reload();
                messenger.showSnackBar(SnackBar(content: Text('Order updated to ${status.toUpperCase()}')));
              },
              child: const Text('Save & Update'),
            ),
          ],
        ),
      ),
    );
  }

  void _openAddProductDialog(BuildContext context) {
    _openEditProductDialog(context, null);
  }

  void _openEditProductDialog(BuildContext context, VendorProduct? p) {
    final title = TextEditingController(text: p?.title ?? '');
    final brand = TextEditingController(text: p?.brand ?? '');
    String category = p?.category ?? 'supplements';
    final desc = TextEditingController(text: p?.description ?? '');
    final price = TextEditingController(text: p != null ? (p.pricePaise / 100).round().toString() : '999');
    final origPrice = TextEditingController(text: p != null ? (p.originalPricePaise / 100).round().toString() : '1299');
    final stock = TextEditingController(text: p != null ? p.stockQuantity.toString() : '20');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p == null ? 'Add New SKU' : 'Edit SKU: ${p.title}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 14),
                TextField(controller: title, decoration: const InputDecoration(labelText: 'Product Title')),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: TextField(controller: brand, decoration: const InputDecoration(labelText: 'Brand'))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: category,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: const [
                        DropdownMenuItem(value: 'supplements', child: Text('Supplements')),
                        DropdownMenuItem(value: 'apparel', child: Text('Apparel')),
                        DropdownMenuItem(value: 'wearables', child: Text('Wearables')),
                        DropdownMenuItem(value: 'gear', child: Text('Gym Gear')),
                      ],
                      onChanged: (v) {
                        if (v != null) setModalState(() => category = v);
                      },
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Price (₹)'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: origPrice, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Original Price (₹)'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: stock, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Stock Units'))),
                ]),
                const SizedBox(height: 10),
                TextField(controller: desc, maxLines: 3, decoration: const InputDecoration(labelText: 'Description')),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    final pPaise = (int.tryParse(price.text) ?? 999) * 100;
                    final oPaise = (int.tryParse(origPrice.text) ?? 1299) * 100;
                    final st = int.tryParse(stock.text) ?? 20;

                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.pop(ctx);
                    final api = context.read<PartnerSession>().api;
                    if (p == null) {
                      await api.createVendorProduct({
                        'title': title.text.trim(),
                        'brand': brand.text.trim(),
                        'category': category,
                        'description': desc.text.trim().isEmpty ? 'High-quality fitness gear.' : desc.text.trim(),
                        'pricePaise': pPaise,
                        'originalPricePaise': oPaise,
                        'stockQuantity': st,
                        'images': ['https://images.unsplash.com/photo-1579722821273-0f6c7d44362f?w=600'],
                        'specs': {'Standard': 'Certified'},
                      });
                    } else {
                      await api.updateVendorProduct(p.id, {
                        'title': title.text.trim(),
                        'brand': brand.text.trim(),
                        'category': category,
                        'description': desc.text.trim(),
                        'pricePaise': pPaise,
                        'originalPricePaise': oPaise,
                        'stockQuantity': st,
                      });
                    }
                    _reload();
                    messenger.showSnackBar(const SnackBar(content: Text('SKU saved successfully!')));
                  },
                  child: Text(p == null ? 'Add SKU to Catalog' : 'Save Changes'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MerchantOnboardingForm extends StatefulWidget {
  const _MerchantOnboardingForm({required this.initialVendor, required this.onSaved});

  final VendorProfile? initialVendor;
  final VoidCallback onSaved;

  @override
  State<_MerchantOnboardingForm> createState() => _MerchantOnboardingFormState();
}

class _MerchantOnboardingFormState extends State<_MerchantOnboardingForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _businessName;
  late final TextEditingController _gstin;
  late final TextEditingController _bankName;
  late final TextEditingController _bankAccount;
  late final TextEditingController _ifsc;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final v = widget.initialVendor;
    _businessName = TextEditingController(text: v?.businessName ?? 'Apex Fitness Gear & Nutrition');
    _gstin = TextEditingController(text: v?.gstin ?? '29AABCU9603R1ZM');
    _bankName = TextEditingController(text: v?.bankName ?? 'HDFC Bank');
    _bankAccount = TextEditingController(text: v?.bankAccountNo ?? '50100456789123');
    _ifsc = TextEditingController(text: v?.ifscCode ?? 'HDFC0000123');
  }

  @override
  void dispose() {
    _businessName.dispose();
    _gstin.dispose();
    _bankName.dispose();
    _bankAccount.dispose();
    _ifsc.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await context.read<PartnerSession>().api.saveVendorProfile({
        'businessName': _businessName.text.trim(),
        'gstin': _gstin.text.trim(),
        'bankName': _bankName.text.trim(),
        'bankAccountNo': _bankAccount.text.trim(),
        'ifscCode': _ifsc.text.trim(),
      });
      widget.onSaved();
      if (mounted) showSnack(context, 'Merchant details & GSTIN verification updated!');
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            const Icon(Icons.verified_user, color: FkColors.lime, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Merchant Verification Status', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 2),
                Text('Status: ${(widget.initialVendor?.verificationStatus ?? 'Verified').toUpperCase()}',
                    style: const TextStyle(color: FkColors.lime, fontWeight: FontWeight.bold, fontSize: 12)),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          const Text('Business & Tax Details', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 8),
          TextFormField(
            controller: _businessName,
            decoration: const InputDecoration(labelText: 'Registered Business Name'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Enter business name' : null,
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _gstin,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'GSTIN Number (Goods & Services Tax ID)'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Enter GSTIN' : null,
          ),
          const SizedBox(height: 20),
          const Text('Payout Bank Account Details', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 8),
          TextFormField(
            controller: _bankName,
            decoration: const InputDecoration(labelText: 'Bank Name'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Enter bank name' : null,
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _bankAccount,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Bank Account Number'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Enter account number' : null,
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _ifsc,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'IFSC Code'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Enter IFSC code' : null,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Text('Save & Verify Merchant Profile'),
          ),
        ],
      ),
    );
  }
}
