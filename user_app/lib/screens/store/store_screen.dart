import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart' show formatPaise, formatDate;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/cart.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'cart_checkout_screen.dart';
import 'order_tracking_screen.dart';
import 'product_details_screen.dart';

/// Page size used by `GET /marketplace/products` (backend default `limit`).
const _pageSize = 20;

typedef _Cat = ({String id, String label, IconData icon, String image, Color color});

const _categories = <_Cat>[
  (id: 'all', label: 'All', icon: Icons.grid_view_rounded, image: AppImages.gymFloor, color: AppColors.ink),
  (id: 'supplements', label: 'Supplements', icon: Icons.science_rounded, image: AppImages.supplements, color: AppColors.primary),
  (id: 'apparel', label: 'Apparel', icon: Icons.checkroom_rounded, image: AppImages.running, color: AppColors.blue),
  (id: 'wearables', label: 'Wearables', icon: Icons.watch_rounded, image: AppImages.running, color: AppColors.purple),
  (id: 'gear', label: 'Gym gear', icon: Icons.fitness_center_rounded, image: AppImages.homeWorkout, color: AppColors.green),
];

_Cat _cat(String id) => _categories.firstWhere((c) => c.id == id, orElse: () => _categories.first);

/// FitKey Store — Blinkit-style quick-commerce for supplements, apparel, wearables and gear.
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key});

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  final _search = TextEditingController();
  Timer? _debounce;

  String _category = 'all';
  List<MarketplaceProduct> _products = [];
  Object? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  int _req = 0;

  String get _query => _search.text.trim();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final req = ++_req;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await context.read<Session>().api.marketplaceProducts(
            category: _category == 'all' ? null : _category,
            q: _query.isEmpty ? null : _query,
          );
      if (!mounted || req != _req) return;
      setState(() {
        _products = list;
        _page = 1;
        _hasMore = list.length >= _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || req != _req) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    final req = _req;
    setState(() => _loadingMore = true);
    try {
      final list = await context.read<Session>().api.marketplaceProducts(
            category: _category == 'all' ? null : _category,
            q: _query.isEmpty ? null : _query,
            page: _page + 1,
          );
      if (!mounted || req != _req) return;
      setState(() {
        final seen = _products.map((p) => p.id).toSet();
        _products = [..._products, ...list.where((p) => !seen.contains(p.id))];
        _page++;
        _hasMore = list.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || req != _req) return;
      setState(() => _loadingMore = false);
      toast(context, friendlyError(e), error: true);
    }
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), _load);
  }

  void _selectCategory(String id) {
    if (id == _category) return;
    _category = id;
    _load();
  }

  void _clearFilters() {
    _search.clear();
    _category = 'all';
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final cartEmpty = context.select<Cart, bool>((c) => c.isEmpty);
    final browsing = _category == 'all' && _query.isEmpty;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('FitKey Store'),
          Text('Whey, gear & wearables at your door',
              style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
        ]),
        actions: [
          IconButton(
            tooltip: 'My orders',
            icon: const Icon(Icons.receipt_long_rounded),
            onPressed: () => _openOrders(context),
          ),
          const CartIconButton(),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.extentAfter < 500) _loadMore();
            return false;
          },
          child: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _load,
            child: CustomScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _searchHeader()),
                if (browsing) ...[
                  const SliverToBoxAdapter(child: _PerksStrip()),
                  SliverToBoxAdapter(child: _CategoryTiles(onSelect: _selectCategory)),
                ],
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverToBoxAdapter(child: _gridTitle()),
                ),
                ..._grid(),
                SliverToBoxAdapter(
                  child: _loadingMore
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: Center(
                              child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.6))),
                        )
                      : const SizedBox.shrink(),
                ),
                SliverToBoxAdapter(child: SizedBox(height: cartEmpty ? 24 : 100)),
              ],
            ),
          ),
        ),
        const Align(alignment: Alignment.bottomCenter, child: FloatingCartBar()),
      ]),
    );
  }

  Widget _searchHeader() {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 14),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: RotatingSearchBar(
            hints: const ["'whey protein'", "'creatine'", "'running watch'", "'lifting belt'", "'training shorts'"],
            controller: _search,
            onChanged: _onQueryChanged,
            onSubmitted: (_) {
              _debounce?.cancel();
              _load();
            },
          ),
        ),
        const SizedBox(height: 12),
        ChoiceChips<String>(
          options: _categories.map((c) => c.id).toList(),
          selected: _category,
          onSelected: _selectCategory,
          label: (id) => _cat(id).label,
          icon: (id) => _cat(id).icon,
        ),
      ]),
    );
  }

  Widget _gridTitle() {
    final title = _query.isNotEmpty
        ? 'Results for "$_query"'
        : _category == 'all'
            ? 'Bestsellers & new arrivals'
            : _cat(_category).label;
    final sub = _loading || _error != null
        ? null
        : '${_products.length}${_hasMore ? '+' : ''} product${_products.length == 1 ? '' : 's'}'
            '${_query.isNotEmpty && _category != 'all' ? ' in ${_cat(_category).label}' : ''}';
    return SectionTitle(title, subtitle: sub, padding: const EdgeInsets.fromLTRB(0, 22, 0, 14));
  }

  List<Widget> _grid() {
    const delegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      mainAxisExtent: 296,
    );
    if (_loading) {
      return [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid(
            gridDelegate: delegate,
            delegate: SliverChildBuilderDelegate((_, _) => const _ProductCardSkeleton(), childCount: 6),
          ),
        ),
      ];
    }
    if (_error != null) {
      return [SliverToBoxAdapter(child: ErrorView(error: _error!, onRetry: _load))];
    }
    if (_products.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: EmptyView(
            icon: Icons.search_off_rounded,
            title: _query.isEmpty ? 'Nothing here yet' : 'No matches for "$_query"',
            message: _query.isEmpty
                ? 'New ${_cat(_category).label.toLowerCase()} are added by our partner brands regularly.'
                : 'Try a different word, or browse all categories.',
            action: SizedBox(
              width: 190,
              child: OutlinedButton(onPressed: _clearFilters, child: const Text('Show all products')),
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: delegate,
          delegate: SliverChildBuilderDelegate((_, i) => _ProductCard(product: _products[i]), childCount: _products.length),
        ),
      ),
    ];
  }

  void _openOrders(BuildContext context) {
    final nav = Navigator.of(context);
    showAppSheet<String>(context, builder: (_) => const _MyOrdersSheet()).then((orderId) {
      if (orderId != null) nav.push(MaterialPageRoute(builder: (_) => OrderTrackingScreen(orderId: orderId)));
    });
  }
}

// ---------------------------------------------------------------------------

class _PerksStrip extends StatelessWidget {
  const _PerksStrip();

  @override
  Widget build(BuildContext context) {
    Widget perk(IconData i, String t, Color c) => Expanded(
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(i, size: 16, color: c),
            const SizedBox(width: 5),
            Flexible(
              child: Text(t,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.text2)),
            ),
          ]),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 6),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), boxShadow: AppShadows.soft),
      child: Row(children: [
        perk(Icons.local_shipping_rounded, 'No delivery fee', AppColors.green),
        perk(Icons.payments_rounded, 'Cash on delivery', AppColors.amber),
        perk(Icons.route_rounded, 'Live tracking', AppColors.blue),
      ]),
    );
  }
}

class _CategoryTiles extends StatelessWidget {
  const _CategoryTiles({required this.onSelect});
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final cats = _categories.where((c) => c.id != 'all').toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionTitle('Shop by category', padding: EdgeInsets.fromLTRB(0, 22, 0, 12)),
        Row(children: [
          for (final (i, c) in cats.indexed) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: Tap(
                onTap: () => onSelect(c.id),
                child: Column(children: [
                  AspectRatio(
                    aspectRatio: 0.9,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: AppShadows.soft,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(fit: StackFit.expand, children: [
                        Image.asset(c.image, fit: BoxFit.cover),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, c.color.withValues(alpha: 0.75)],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 8,
                          bottom: 8,
                          child: Icon(c.icon, color: Colors.white, size: 20),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(c.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ],
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product});
  final MarketplaceProduct product;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final qty = context.select<Cart, int>((c) => c.qtyOf(p.id));
    final soldOut = p.stockQuantity <= 0;
    final hasMrp = p.originalPricePaise > p.pricePaise;

    return Tap(
      onTap: () => push(context, ProductDetailsScreen(product: p)),
      scale: 0.98,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: AppShadows.card,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: 150,
            child: Stack(fit: StackFit.expand, children: [
              Opacity(
                opacity: soldOut ? 0.5 : 1,
                child: NetImage(p.images.isEmpty ? null : p.images.first,
                    fallback: productFallbackImage(p.category), height: 150),
              ),
              if (p.discountPercent > 0)
                Positioned(
                  top: 0,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(7, 6, 7, 7),
                    decoration: const BoxDecoration(
                      color: AppColors.blue,
                      borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                    ),
                    child: Text('${p.discountPercent}%\nOFF',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800, height: 1.1)),
                  ),
                ),
              if (soldOut)
                const Positioned(left: 10, bottom: 10, child: Tag('SOLD OUT', color: AppColors.ink, solid: true, dense: true))
              else if (p.stockQuantity <= 10)
                Positioned(
                  left: 10,
                  bottom: 10,
                  child: Tag('Only ${p.stockQuantity} left', color: AppColors.red, bg: AppColors.surface, dense: true),
                ),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.brand.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: AppColors.text3, letterSpacing: 0.6)),
                const SizedBox(height: 3),
                Text(p.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.3)),
                const Spacer(),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(formatPaise(p.pricePaise),
                          maxLines: 1, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                      if (hasMrp)
                        Text(formatPaise(p.originalPricePaise),
                            maxLines: 1,
                            style: const TextStyle(
                                fontSize: 11.5, color: AppColors.text3, decoration: TextDecoration.lineThrough)),
                    ]),
                  ),
                  QtyStepper(
                    qty: qty,
                    compact: true,
                    max: maxOrderQty(p),
                    onChanged: (q) => context.read<Cart>().setQty(p, q),
                  ),
                ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ProductCardSkeleton extends StatelessWidget {
  const _ProductCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Container(
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(18)),
        clipBehavior: Clip.antiAlias,
        child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SkeletonBox(height: 150, radius: 0),
          Padding(
            padding: EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SkeletonBox(height: 10, width: 60),
              SizedBox(height: 8),
              SkeletonBox(height: 13),
              SizedBox(height: 6),
              SkeletonBox(height: 13, width: 100),
              SizedBox(height: 24),
              Row(children: [
                SkeletonBox(height: 16, width: 60),
                Spacer(),
                SkeletonBox(height: 34, width: 72),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Bottom sheet listing the member's orders; pops with the tapped order's id.
class _MyOrdersSheet extends StatefulWidget {
  const _MyOrdersSheet();

  @override
  State<_MyOrdersSheet> createState() => _MyOrdersSheetState();
}

class _MyOrdersSheetState extends State<_MyOrdersSheet> {
  late Future<List<MarketplaceOrder>> _future = context.read<Session>().api.myMarketplaceOrders();

  void _retry() => setState(() => _future = context.read<Session>().api.myMarketplaceOrders());

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text('My orders', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
        ),
        Expanded(
          child: AsyncBody<List<MarketplaceOrder>>(
            future: _future,
            onRetry: _retry,
            loading: const SkeletonList(count: 4, itemHeight: 64),
            builder: (context, orders) {
              if (orders.isEmpty) {
                return EmptyView(
                  icon: Icons.receipt_long_rounded,
                  title: 'No orders yet',
                  message: 'Everything you buy from the FitKey Store will show up here.',
                  action: SizedBox(
                    width: 170,
                    child: AppButton(label: 'Start shopping', height: 46, onPressed: () => Navigator.pop(context)),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: orders.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _OrderTile(order: orders[i]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order});
  final MarketplaceOrder order;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final color = orderStatusColor(o.status);
    final names = o.items.map((i) => i.quantity > 1 ? '${i.title} ×${i.quantity}' : i.title).join(', ');
    return AppCard(
      border: true,
      shadow: false,
      padding: const EdgeInsets.all(14),
      onTap: () => Navigator.pop(context, o.id),
      child: Row(children: [
        IconBubble(o.status == 'delivered' ? Icons.inventory_rounded : Icons.local_shipping_rounded, color: color, size: 46),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Tag(orderStatusLabel(o.status).toUpperCase(), color: color, dense: true),
              const Spacer(),
              Text(formatDate(o.createdAt), style: const TextStyle(fontSize: 12, color: AppColors.text3)),
            ]),
            const SizedBox(height: 6),
            Text(names.isEmpty ? 'Order #${o.id.substring(0, 8).toUpperCase()}' : names,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
            const SizedBox(height: 4),
            Text('${formatPaise(o.totalAmountPaise)} · ${paymentStatusLabel(o.paymentStatus)}',
                style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
      ]),
    );
  }
}
