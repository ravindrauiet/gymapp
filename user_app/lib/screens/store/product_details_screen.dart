import 'package:fitkey_core/fitkey_core.dart' show formatPaise;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/cart.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'cart_checkout_screen.dart';

/// Product page: gallery, price & savings, stock, specs, description and seller.
class ProductDetailsScreen extends StatefulWidget {
  const ProductDetailsScreen({super.key, required this.product});

  final MarketplaceProduct product;

  @override
  State<ProductDetailsScreen> createState() => _ProductDetailsScreenState();
}

class _ProductDetailsScreenState extends State<ProductDetailsScreen> {
  late MarketplaceProduct _p = widget.product;
  final _pager = PageController();
  int _image = 0;
  bool _refreshing = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  /// The list endpoint omits the seller and may be stale — fetch the live product (price, stock, vendor).
  Future<void> _refresh() async {
    try {
      final fresh = await context.read<Session>().api.marketplaceProduct(widget.product.id);
      if (!mounted) return;
      setState(() {
        _p = fresh;
        _refreshing = false;
      });
      // Keep the cart in line with the latest stock.
      final cart = context.read<Cart>();
      final inCart = cart.qtyOf(fresh.id);
      if (inCart > 0) cart.setQty(fresh, inCart.clamp(0, maxOrderQty(fresh)));
    } catch (_) {
      // The product we were given is still perfectly usable; keep showing it.
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _setQty(int q) {
    final cart = context.read<Cart>();
    final before = cart.qtyOf(_p.id);
    cart.setQty(_p, q);
    if (before == 0 && q > 0) toast(context, 'Added to cart', icon: Icons.shopping_bag_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final qty = context.select<Cart, int>((c) => c.qtyOf(p.id));
    final cartCount = context.select<Cart, int>((c) => c.itemCount);
    final max = maxOrderQty(p);
    final hasMrp = p.originalPricePaise > p.pricePaise;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(p.brand, overflow: TextOverflow.ellipsis),
        actions: const [CartIconButton(), SizedBox(width: 4)],
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _gallery(p),
            Container(
              color: AppColors.surface,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(p.brand.toUpperCase(),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.8)),
                  ),
                  const SizedBox(width: 8),
                  Tag(_categoryLabel(p.category), color: AppColors.text2, bg: AppColors.surfaceAlt, dense: true),
                ]),
                const SizedBox(height: 8),
                Text(p.title,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, height: 1.3, letterSpacing: -0.3)),
                const SizedBox(height: 14),
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Flexible(
                    child: PriceText(
                      price: formatPaise(p.pricePaise),
                      mrp: hasMrp ? 'MRP ${formatPaise(p.originalPricePaise)}' : null,
                      size: 24,
                    ),
                  ),
                  if (p.discountPercent > 0) ...[
                    const SizedBox(width: 8),
                    Tag('${p.discountPercent}% OFF', color: AppColors.blue, solid: true),
                  ],
                ]),
                if (hasMrp) ...[
                  const SizedBox(height: 6),
                  Text('You save ${formatPaise(p.originalPricePaise - p.pricePaise)}',
                      style: const TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: 13.5)),
                ],
                const SizedBox(height: 14),
                _StockLine(stock: p.stockQuantity),
              ]),
            ),
            const SizedBox(height: 10),
            const _Perks(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (p.specs.isNotEmpty) ...[
                  SectionTitle(p.category == 'supplements' ? 'Nutrition & specs' : 'Specifications',
                      padding: const EdgeInsets.fromLTRB(0, 24, 0, 12)),
                  _SpecsTable(specs: p.specs),
                ],
                if (p.description.trim().isNotEmpty) ...[
                  const SectionTitle('About this product', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                  AppCard(
                    child: Text(p.description.trim(),
                        style: const TextStyle(color: AppColors.text2, height: 1.55, fontSize: 14)),
                  ),
                ],
                const SectionTitle('Sold by', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                AppCard(
                  child: Row(children: [
                    const IconBubble(Icons.storefront_rounded, color: AppColors.purple, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _refreshing && p.vendorName == null
                          ? const Shimmer(child: SkeletonBox(height: 16, width: 140))
                          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(p.vendorName ?? 'FitKey partner store',
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                              const SizedBox(height: 2),
                              const Text('Ships directly to your address',
                                  style: TextStyle(fontSize: 12.5, color: AppColors.text2)),
                            ]),
                    ),
                  ]),
                ),
              ]),
            ),
          ],
        ),
      ),
      bottomNavigationBar: BottomActionBar(
        leading: qty == 0
            ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(formatPaise(p.pricePaise),
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                if (hasMrp)
                  Text(formatPaise(p.originalPricePaise),
                      style: const TextStyle(
                          fontSize: 12.5, color: AppColors.text3, decoration: TextDecoration.lineThrough)),
              ])
            : QtyStepper(qty: qty, max: max, onChanged: _setQty),
        child: max <= 0
            ? const AppButton(label: 'Out of stock', onPressed: null)
            : qty == 0
                ? AppButton(label: 'Add to cart', icon: Icons.add_shopping_cart_rounded, onPressed: () => _setQty(1))
                : AppButton(
                    label: 'Go to cart · $cartCount item${cartCount == 1 ? '' : 's'}',
                    color: AppColors.green,
                    trailing: const Icon(Icons.arrow_forward_rounded, size: 20),
                    onPressed: () => push(context, const CartCheckoutScreen()),
                  ),
      ),
    );
  }

  Widget _gallery(MarketplaceProduct p) {
    final images = p.images.isEmpty ? <String?>[null] : p.images;
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(children: [
        SizedBox(
          height: 330,
          child: PageView.builder(
            controller: _pager,
            itemCount: images.length,
            onPageChanged: (i) => setState(() => _image = i),
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Stack(fit: StackFit.expand, children: [
                NetImage(images[i], fallback: productFallbackImage(p.category), radius: 22),
                if (p.stockQuantity <= 0)
                  Container(
                    decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(22)),
                    alignment: Alignment.center,
                    child: const Tag('OUT OF STOCK', color: AppColors.ink, solid: true),
                  ),
              ]),
            ),
          ),
        ),
        if (images.length > 1) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: images.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => Tap(
                onTap: () => _pager.animateToPage(i, duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 56,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: i == _image ? AppColors.primary : AppColors.line, width: i == _image ? 2 : 1),
                  ),
                  child: NetImage(images[i], fallback: productFallbackImage(p.category), radius: 9),
                ),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

String _categoryLabel(String c) => switch (c) {
      'supplements' => 'Supplements',
      'apparel' => 'Apparel',
      'wearables' => 'Wearables',
      'gear' => 'Gym gear',
      _ => c,
    };

class _StockLine extends StatelessWidget {
  const _StockLine({required this.stock});
  final int stock;

  @override
  Widget build(BuildContext context) {
    final (color, icon, text) = stock <= 0
        ? (AppColors.red, Icons.remove_shopping_cart_rounded, 'Currently out of stock')
        : stock <= 10
            ? (AppColors.amber, Icons.local_fire_department_rounded, 'Hurry — only $stock left in stock')
            : (AppColors.green, Icons.check_circle_rounded, 'In stock · ready to ship');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13))),
      ]),
    );
  }
}

class _Perks extends StatelessWidget {
  const _Perks();

  @override
  Widget build(BuildContext context) {
    Widget perk(IconData i, String t, Color c) => Expanded(
          child: Column(children: [
            IconBubble(i, color: c, size: 40),
            const SizedBox(height: 6),
            Text(t,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.text2, height: 1.25)),
          ]),
        );
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        perk(Icons.local_shipping_rounded, 'No delivery\nfee', AppColors.green),
        perk(Icons.payments_rounded, 'Cash on\ndelivery', AppColors.amber),
        perk(Icons.route_rounded, 'Live order\ntracking', AppColors.blue),
      ]),
    );
  }
}

class _SpecsTable extends StatelessWidget {
  const _SpecsTable({required this.specs});
  final Map<String, dynamic> specs;

  @override
  Widget build(BuildContext context) {
    final entries = specs.entries.toList();
    return AppCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(children: [
          for (final (i, e) in entries.indexed)
            Container(
              color: i.isEven ? AppColors.surface : AppColors.bg,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  flex: 2,
                  child: Text(e.key,
                      style: const TextStyle(color: AppColors.text2, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: Text('${e.value}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}
