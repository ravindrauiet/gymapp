import 'package:flutter/material.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import 'cart_checkout_screen.dart';

/// 2.1 Product Details Page (PDP)
class ProductDetailsScreen extends StatefulWidget {
  const ProductDetailsScreen({super.key, required this.product});

  final MarketplaceProduct product;

  @override
  State<ProductDetailsScreen> createState() => _ProductDetailsScreenState();
}

class _ProductDetailsScreenState extends State<ProductDetailsScreen> {
  int _currentImage = 0;

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final images = p.images.isNotEmpty ? p.images : ['https://images.unsplash.com/photo-1579722821273-0f6c7d44362f?w=600'];

    return Scaffold(
      appBar: AppBar(
        title: Text(p.brand),
        actions: [
          IconButton(
            tooltip: 'View Cart',
            icon: const Icon(Icons.shopping_bag_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CartCheckoutScreen()),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: const BoxDecoration(
            color: FkColors.surface,
            border: Border(top: BorderSide(color: FkColors.outline)),
          ),
          child: Row(children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Total Price', style: TextStyle(color: FkColors.textSecondary, fontSize: 11)),
                Text(formatInr(p.pricePaise),
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: FkColors.lime)),
              ],
            ),
            const SizedBox(width: 24),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text('Add to Cart'),
                onPressed: () {
                  CartController.instance.add(p);
                  showSnack(context, 'Added ${p.title} to cart');
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CartCheckoutScreen()),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          // Image Carousel
          SizedBox(
            height: 260,
            child: PageView.builder(
              itemCount: images.length,
              onPageChanged: (i) => setState(() => _currentImage = i),
              itemBuilder: (_, idx) => Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  image: DecorationImage(image: NetworkImage(images[idx]), fit: BoxFit.cover),
                  color: const Color(0xFF252B35),
                ),
              ),
            ),
          ),
          if (images.length > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(images.length, (i) => Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: _currentImage == i ? 16 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _currentImage == i ? FkColors.lime : Colors.white24,
                  borderRadius: BorderRadius.circular(3),
                ),
              )),
            ),
          ],
          const SizedBox(height: 16),

          // Brand & Category Chip
          Row(children: [
            Text(p.brand.toUpperCase(),
                style: const TextStyle(color: FkColors.lime, fontWeight: FontWeight.w800, fontSize: 13)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2F37),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                p.category.toUpperCase(),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: FkColors.textSecondary),
              ),
            ),
          ]),
          const SizedBox(height: 6),

          // Title
          Text(p.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),

          // Pricing & Discount
          Row(children: [
            Text(formatInr(p.pricePaise),
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white)),
            const SizedBox(width: 10),
            if (p.originalPricePaise > p.pricePaise) ...[
              Text(
                formatInr(p.originalPricePaise),
                style: const TextStyle(
                  fontSize: 16,
                  color: FkColors.textSecondary,
                  decoration: TextDecoration.lineThrough,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: FkColors.orange.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${p.discountPercent}% OFF',
                  style: const TextStyle(color: FkColors.orange, fontWeight: FontWeight.w800, fontSize: 11),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.inventory_2, size: 16, color: p.stockQuantity > 0 ? FkColors.lime : Colors.red),
            const SizedBox(width: 6),
            Text(
              p.stockQuantity > 0 ? 'In Stock (${p.stockQuantity} units available)' : 'Out of stock',
              style: TextStyle(fontSize: 12, color: p.stockQuantity > 0 ? FkColors.lime : Colors.red),
            ),
          ]),
          const Divider(height: 32),

          // Description
          const Text('Product Description', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 8),
          Text(
            p.description,
            style: const TextStyle(color: FkColors.textSecondary, height: 1.5, fontSize: 14),
          ),
          const SizedBox(height: 24),

          // Nutritional or Technical Specs
          Text(
            p.category == 'supplements' ? 'Nutritional & Ingredient Specs' : 'Technical Specifications',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 10),
          if (p.specs.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: p.specs.entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: Text(e.key, style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(e.value.toString(),
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        ),
                      ],
                    ),
                  )).toList(),
                ),
              ),
            )
          else
            const Text('Standard certified fitness specification compliant.',
                style: TextStyle(color: FkColors.textSecondary)),
        ],
      ),
    );
  }
}
