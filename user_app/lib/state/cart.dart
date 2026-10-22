import 'package:flutter/foundation.dart';

import '../data/models.dart';

class CartItem {
  CartItem({required this.product, this.quantity = 1});
  final MarketplaceProduct product;
  int quantity;
}

/// Marketplace cart shared across the store, product and checkout screens (provided in main.dart).
class Cart extends ChangeNotifier {
  final List<CartItem> _items = [];

  List<CartItem> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  int get itemCount => _items.fold(0, (sum, i) => sum + i.quantity);
  int get totalPaise => _items.fold(0, (sum, i) => sum + i.product.pricePaise * i.quantity);
  int get mrpTotalPaise => _items.fold(
      0,
      (sum, i) =>
          sum + (i.product.originalPricePaise > i.product.pricePaise ? i.product.originalPricePaise : i.product.pricePaise) * i.quantity);
  int get savingsPaise => mrpTotalPaise - totalPaise;

  int qtyOf(String productId) {
    for (final i in _items) {
      if (i.product.id == productId) return i.quantity;
    }
    return 0;
  }

  /// The API rejects more than this many units of one product per order.
  static const maxPerLine = 20;

  /// Sets the quantity of [product]; 0 removes it. Capped at stock and [maxPerLine].
  void setQty(MarketplaceProduct product, int qty) {
    final capped = qty.clamp(0, product.stockQuantity < maxPerLine ? product.stockQuantity : maxPerLine);
    final idx = _items.indexWhere((i) => i.product.id == product.id);
    if (capped <= 0) {
      if (idx >= 0) _items.removeAt(idx);
    } else if (idx >= 0) {
      _items[idx].quantity = capped;
    } else {
      _items.add(CartItem(product: product, quantity: capped));
    }
    notifyListeners();
  }

  void clear() {
    _items.clear();
    notifyListeners();
  }
}
