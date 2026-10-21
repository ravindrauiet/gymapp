import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import 'cart_checkout_screen.dart';
import 'order_tracking_screen.dart';
import 'product_details_screen.dart';

/// 2. Marketplace / Store Module (FITKEY Consumer App)
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key});

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _search = TextEditingController();

  final List<({String key, String label, IconData icon})> _categories = const [
    (key: 'all', label: 'All SKUs', icon: Icons.grid_view),
    (key: 'supplements', label: 'Supplements', icon: Icons.medication_liquid),
    (key: 'apparel', label: 'Apparel', icon: Icons.checkroom),
    (key: 'wearables', label: 'Wearables', icon: Icons.watch),
    (key: 'gear', label: 'Gym Gears', icon: Icons.fitness_center),
  ];

  late Future<List<MarketplaceProduct>> _future;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _categories.length, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) _reload();
    });
    _load();
  }

  void _load() {
    final cat = _categories[_tabController.index].key;
    final q = _search.text.trim();
    _future = context.read<Session>().api.marketplaceProducts(
          category: cat == 'all' ? null : cat,
          q: q.isEmpty ? null : q,
        );
  }

  void _reload() => setState(_load);

  @override
  void dispose() {
    _tabController.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FitKey Marketplace'),
        actions: [
          IconButton(
            tooltip: 'My Orders',
            icon: const Icon(Icons.receipt_long),
            onPressed: () => _openMyOrdersSheet(context),
          ),
          IconButton(
            tooltip: 'Cart',
            icon: const Icon(Icons.shopping_bag_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CartCheckoutScreen()),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(110),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: 'Search supplements, wearables, apparel, gears...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _search.clear();
                              _reload();
                            },
                          )
                        : null,
                    isDense: true,
                  ),
                  onSubmitted: (_) => _reload(),
                ),
              ),
              TabBar(
                controller: _tabController,
                isScrollable: true,
                tabs: _categories.map((c) => Tab(icon: Icon(c.icon, size: 18), text: c.label)).toList(),
              ),
            ],
          ),
        ),
      ),
      body: FutureBuilder<List<MarketplaceProduct>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ErrorState(message: errorMessage(snap.error!), onRetry: _reload);
          }

          final products = snap.data!;
          if (products.isEmpty) {
            return const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No products found',
              message: 'Try selecting another category or clear search filters.',
            );
          }

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.68,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
              ),
              itemCount: products.length,
              itemBuilder: (context, idx) {
                final p = products[idx];
                final img = p.images.isNotEmpty ? p.images.first : 'https://images.unsplash.com/photo-1579722821273-0f6c7d44362f?w=600';

                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ProductDetailsScreen(product: p)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.network(img, fit: BoxFit.cover),
                              if (p.discountPercent > 0)
                                Positioned(
                                  top: 8,
                                  left: 8,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: FkColors.orange,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '${p.discountPercent}% OFF',
                                      style: const TextStyle(
                                          color: Colors.black, fontSize: 10, fontWeight: FontWeight.w900),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  p.brand.toUpperCase(),
                                  style: const TextStyle(
                                      color: FkColors.textSecondary, fontSize: 10, fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  p.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                                ),
                                const Spacer(),
                                Row(
                                  children: [
                                    Text(
                                      formatInr(p.pricePaise),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w900, color: FkColors.lime, fontSize: 14),
                                    ),
                                    const Spacer(),
                                    const Icon(Icons.arrow_forward_ios, size: 12, color: FkColors.textSecondary),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  void _openMyOrdersSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.75,
        child: const _MyOrdersSheet(),
      ),
    );
  }
}

class _MyOrdersSheet extends StatelessWidget {
  const _MyOrdersSheet();

  @override
  Widget build(BuildContext context) {
    final api = context.read<Session>().api;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Orders'),
        automaticallyImplyLeading: false,
        actions: [IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context))],
      ),
      body: FutureBuilder<List<MarketplaceOrder>>(
        future: api.myMarketplaceOrders(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final orders = snap.data ?? [];
          if (orders.isEmpty) {
            return const EmptyState(
              icon: Icons.receipt_long,
              title: 'No orders yet',
              message: 'Your purchased marketplace items will appear here.',
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: orders.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, idx) {
              final o = orders[idx];
              return Card(
                child: ListTile(
                  title: Text('Order #${o.id.substring(0, 8)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${o.items.length} items · ${formatInr(o.totalAmountPaise)} · ${o.status.toUpperCase()}'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => OrderTrackingScreen(orderId: o.id)),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
