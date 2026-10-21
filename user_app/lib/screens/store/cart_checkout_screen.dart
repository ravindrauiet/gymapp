import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import 'order_tracking_screen.dart';

/// Simple Cart Item model
class CartItem {
  CartItem({required this.product, this.quantity = 1});
  final MarketplaceProduct product;
  int quantity;
}

/// Global session-level shopping cart
class CartController extends ChangeNotifier {
  static final CartController instance = CartController._();
  CartController._();

  final List<CartItem> _items = [];

  List<CartItem> get items => List.unmodifiable(_items);
  int get itemCount => _items.fold(0, (sum, i) => sum + i.quantity);
  int get totalPaise => _items.fold(0, (sum, i) => sum + (i.product.pricePaise * i.quantity));

  void add(MarketplaceProduct product, {int qty = 1}) {
    final idx = _items.indexWhere((i) => i.product.id == product.id);
    if (idx >= 0) {
      _items[idx].quantity += qty;
    } else {
      _items.add(CartItem(product: product, quantity: qty));
    }
    notifyListeners();
  }

  void updateQuantity(String productId, int quantity) {
    if (quantity <= 0) {
      _items.removeWhere((i) => i.product.id == productId);
    } else {
      final item = _items.firstWhere((i) => i.product.id == productId);
      item.quantity = quantity;
    }
    notifyListeners();
  }

  void clear() {
    _items.clear();
    notifyListeners();
  }
}

class CartCheckoutScreen extends StatefulWidget {
  const CartCheckoutScreen({super.key});

  @override
  State<CartCheckoutScreen> createState() => _CartCheckoutScreenState();
}

class _CartCheckoutScreenState extends State<CartCheckoutScreen> {
  final _cart = CartController.instance;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _city;
  late final TextEditingController _pincode;

  String _paymentMethod = 'upi'; // upi | card | netbanking | cod
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final user = context.read<Session>().user;
    _name = TextEditingController(text: user?.name ?? '');
    _phone = TextEditingController(text: user?.phone ?? '');
    _address = TextEditingController(text: 'Flat 402, Green Glen Heights, Bellandur');
    _city = TextEditingController(text: user?.city ?? 'Bengaluru');
    _pincode = TextEditingController(text: '560103');

    _cart.addListener(_onCartChanged);
  }

  void _onCartChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _cart.removeListener(_onCartChanged);
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _city.dispose();
    _pincode.dispose();
    super.dispose();
  }

  Future<void> _checkout() async {
    if (_cart.items.isEmpty) {
      showSnack(context, 'Your cart is empty', error: true);
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);
    try {
      final order = await context.read<Session>().api.createMarketplaceOrder(
        items: _cart.items.map((i) => (productId: i.product.id, quantity: i.quantity)).toList(),
        shippingAddress: {
          'fullName': _name.text.trim(),
          'phone': _phone.text.trim(),
          'addressLine': _address.text.trim(),
          'city': _city.text.trim(),
          'pincode': _pincode.text.trim(),
        },
        paymentMethod: _paymentMethod,
      );

      _cart.clear();

      if (mounted) {
        showSnack(context, 'Order placed successfully! Tracking live order.');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => OrderTrackingScreen(orderId: order.id)),
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _cart.items;
    final total = _cart.totalPaise;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Cart & Checkout'),
      ),
      body: items.isEmpty
          ? const EmptyState(
              icon: Icons.shopping_cart_outlined,
              title: 'Your cart is empty',
              message: 'Explore fitness supplements, gym gear, wearables and apparel.',
            )
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: [
                  const SectionHeader('Cart Items'),
                  ...items.map((it) => Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(children: [
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                image: it.product.images.isNotEmpty
                                    ? DecorationImage(
                                        image: NetworkImage(it.product.images.first), fit: BoxFit.cover)
                                    : null,
                                color: const Color(0xFF252B35),
                              ),
                              child: it.product.images.isEmpty ? const Icon(Icons.fitness_center) : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(it.product.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                                const SizedBox(height: 2),
                                Text(it.product.brand,
                                    style: const TextStyle(color: FkColors.textSecondary, fontSize: 12)),
                                const SizedBox(height: 4),
                                Text(formatInr(it.product.pricePaise),
                                    style: const TextStyle(color: FkColors.lime, fontWeight: FontWeight.w800)),
                              ]),
                            ),
                            Row(children: [
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, size: 20),
                                onPressed: () => _cart.updateQuantity(it.product.id, it.quantity - 1),
                              ),
                              Text('${it.quantity}', style: const TextStyle(fontWeight: FontWeight.bold)),
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline, size: 20, color: FkColors.lime),
                                onPressed: () => _cart.updateQuantity(it.product.id, it.quantity + 1),
                              ),
                            ]),
                          ]),
                        ),
                      )),
                  const SizedBox(height: 12),

                  // Shipping Address
                  const SectionHeader('Delivery Address'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(children: [
                        TextFormField(
                          controller: _name,
                          decoration: const InputDecoration(labelText: 'Full Name'),
                          validator: (v) => (v ?? '').trim().isEmpty ? 'Enter recipient name' : null,
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Contact Phone'),
                          validator: (v) => (v ?? '').trim().length < 10 ? 'Enter valid phone number' : null,
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _address,
                          decoration: const InputDecoration(labelText: 'House / Street / Flat Address'),
                          validator: (v) => (v ?? '').trim().isEmpty ? 'Enter delivery address' : null,
                        ),
                        const SizedBox(height: 10),
                        Row(children: [
                          Expanded(
                            child: TextFormField(
                              controller: _city,
                              decoration: const InputDecoration(labelText: 'City'),
                              validator: (v) => (v ?? '').trim().isEmpty ? 'Enter city' : null,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              controller: _pincode,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(labelText: 'Pincode'),
                              validator: (v) => (v ?? '').trim().length < 4 ? 'Enter pincode' : null,
                            ),
                          ),
                        ]),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Payment Options
                  const SectionHeader('Payment Method'),
                  _paymentTile('upi', 'UPI (Google Pay, PhonePe, Paytm)', Icons.account_balance_wallet, FkColors.lime),
                  _paymentTile('card', 'Credit / Debit Cards (Visa, Mastercard, RuPay)', Icons.credit_card, FkColors.sky),
                  _paymentTile('netbanking', 'Netbanking (All Major Indian Banks)', Icons.account_balance, FkColors.orange),
                  _paymentTile('cod', 'Cash on Delivery (COD)', Icons.local_shipping, FkColors.violet),
                  const SizedBox(height: 20),

                  // Order Summary Card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: FkColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: FkColors.outline),
                    ),
                    child: Column(children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text('Items Total', style: TextStyle(color: FkColors.textSecondary)),
                        Text(formatInr(total), style: const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                      const SizedBox(height: 6),
                      const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text('FITKEY Express Shipping', style: TextStyle(color: FkColors.textSecondary)),
                        Text('FREE', style: TextStyle(color: FkColors.lime, fontWeight: FontWeight.w800)),
                      ]),
                      const Divider(height: 20),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text('Total Payable', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                        Text(formatInr(total),
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: FkColors.lime)),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 24),

                  FilledButton(
                    onPressed: _submitting ? null : _checkout,
                    child: _submitting
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : Text('Pay & Place Order · ${formatInr(total)}'),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _paymentTile(String id, String label, IconData icon, Color color) {
    final selected = _paymentMethod == id;
    return InkWell(
      onTap: () => setState(() => _paymentMethod = id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : FkColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? color : FkColors.outline, width: selected ? 1.5 : 1),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          Radio<String>(
            value: id,
            groupValue: _paymentMethod,
            activeColor: color,
            onChanged: (v) {
              if (v != null) setState(() => _paymentMethod = v);
            },
          ),
        ]),
      ),
    );
  }
}
