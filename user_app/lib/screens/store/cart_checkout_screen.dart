import 'dart:math' as math;

import 'package:fitkey_core/fitkey_core.dart' show formatPaise;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/cart.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'order_tracking_screen.dart';

/// The backend accepts at most 20 units of one product per order line.
const kMaxQtyPerItem = 20;

/// Largest quantity of [p] a member can put in the cart (stock and per-line limit).
int maxOrderQty(MarketplaceProduct p) => math.min(p.stockQuantity, kMaxQtyPerItem);

/// Cart → bill → address → payment → place order.
class CartCheckoutScreen extends StatefulWidget {
  const CartCheckoutScreen({super.key});

  @override
  State<CartCheckoutScreen> createState() => _CartCheckoutScreenState();
}

const _paymentMethods = <({String id, String label, String subtitle, IconData icon, Color color})>[
  (id: 'upi', label: 'UPI', subtitle: 'Google Pay, PhonePe, Paytm & more', icon: Icons.qr_code_2_rounded, color: AppColors.green),
  (id: 'card', label: 'Credit / Debit card', subtitle: 'Visa, Mastercard, RuPay', icon: Icons.credit_card_rounded, color: AppColors.blue),
  (id: 'netbanking', label: 'Netbanking', subtitle: 'All major Indian banks', icon: Icons.account_balance_rounded, color: AppColors.purple),
  (id: 'cod', label: 'Cash on delivery', subtitle: 'Pay when your order arrives', icon: Icons.payments_rounded, color: AppColors.amber),
];

class _CartCheckoutScreenState extends State<CartCheckoutScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  final _address = TextEditingController();
  late final TextEditingController _city;
  final _pincode = TextEditingController();

  String _paymentMethod = 'upi';
  bool _submitting = false;
  MarketplaceOrder? _placed;

  @override
  void initState() {
    super.initState();
    final user = context.read<Session>().user;
    _name = TextEditingController(text: user?.name ?? '');
    _phone = TextEditingController(text: user?.phone ?? '');
    _city = TextEditingController(text: user?.city ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _city.dispose();
    _pincode.dispose();
    super.dispose();
  }

  Future<void> _placeOrder() async {
    final cart = context.read<Cart>();
    if (cart.isEmpty) return toast(context, 'Your cart is empty', error: true);
    if (!(_formKey.currentState?.validate() ?? false)) {
      toast(context, 'Please complete your delivery address', error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    try {
      final order = await context.read<Session>().api.createMarketplaceOrder(
            items: cart.items.map((i) => (productId: i.product.id, quantity: i.quantity)).toList(),
            shippingAddress: {
              'fullName': _name.text.trim(),
              'phone': _phone.text.trim(),
              'addressLine': _address.text.trim(),
              'city': _city.text.trim(),
              'pincode': _pincode.text.trim(),
            },
            paymentMethod: _paymentMethod,
          );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _placed = order;
        _submitting = false;
      });
      cart.clear();
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_placed != null) return _OrderPlacedView(order: _placed!);

    final cart = context.watch<Cart>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Checkout'),
          if (!cart.isEmpty)
            Text('${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'} in cart',
                style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600)),
        ]),
      ),
      body: cart.isEmpty
          ? EmptyView(
              icon: Icons.shopping_bag_outlined,
              title: 'Your cart is empty',
              message: 'Whey, gear, wearables and apparel from genuine brands are waiting for you.',
              action: SizedBox(
                width: 200,
                child: AppButton(label: 'Browse the store', height: 48, onPressed: () => Navigator.of(context).maybePop()),
              ),
            )
          : Form(
              key: _formKey,
              // SingleChildScrollView keeps every field mounted so the form validates all of them.
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (cart.savingsPaise > 0) _SavingsBanner(savings: cart.savingsPaise),
                  _ItemsCard(cart: cart),
                  const SectionTitle('Bill details', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                  _BillCard(cart: cart),
                  const SectionTitle('Delivery address',
                      subtitle: 'Where should we send your order?', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                  _addressCard(),
                  const SectionTitle('Payment method', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                  _paymentCard(),
                  const SizedBox(height: 18),
                  const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.verified_user_rounded, size: 16, color: AppColors.green),
                    SizedBox(width: 6),
                    Text('Prices are confirmed by the store when you place the order',
                        style: TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
                  ]),
                ]),
              ),
            ),
      bottomNavigationBar: cart.isEmpty
          ? null
          : BottomActionBar(
              leading: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(formatPaise(cart.totalPaise),
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                const Text('TOTAL', style: TextStyle(fontSize: 11, color: AppColors.text3, fontWeight: FontWeight.w800, letterSpacing: 1)),
              ]),
              child: AppButton(
                label: _paymentMethod == 'cod' ? 'Place order' : 'Pay & place order',
                trailing: const Icon(Icons.arrow_forward_rounded, size: 20),
                busy: _submitting,
                onPressed: _placeOrder,
              ),
            ),
    );
  }

  Widget _addressCard() {
    String? req(String? v, int min, String msg) => (v ?? '').trim().length < min ? msg : null;
    return AppCard(
      child: Column(children: [
        TextFormField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person_outline_rounded)),
          validator: (v) => req(v, 2, 'Enter the recipient\'s name'),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Phone number', prefixIcon: Icon(Icons.phone_outlined)),
          validator: (v) {
            final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
            return digits.length < 10 ? 'Enter a valid 10-digit phone number' : null;
          },
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _address,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.next,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
              labelText: 'House / flat, street, area', prefixIcon: Icon(Icons.home_outlined)),
          validator: (v) => req(v, 5, 'Enter your full delivery address'),
        ),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextFormField(
              controller: _city,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'City'),
              validator: (v) => req(v, 2, 'Enter city'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: _pincode,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              decoration: const InputDecoration(labelText: 'Pincode'),
              validator: (v) => (v ?? '').trim().length != 6 ? 'Enter 6-digit pincode' : null,
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _paymentCard() {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: RadioGroup<String>(
        groupValue: _paymentMethod,
        onChanged: (v) {
          if (v != null) setState(() => _paymentMethod = v);
        },
        child: Column(children: [
          for (final (i, m) in _paymentMethods.indexed) ...[
            if (i > 0) const Divider(indent: 72),
            InkWell(
              onTap: () => setState(() => _paymentMethod = m.id),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(children: [
                  IconBubble(m.icon, color: m.color, size: 42),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                      const SizedBox(height: 2),
                      Text(m.subtitle, style: const TextStyle(fontSize: 12.5, color: AppColors.text2)),
                    ]),
                  ),
                  Radio<String>(value: m.id),
                ]),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _SavingsBanner extends StatelessWidget {
  const _SavingsBanner({required this.savings});
  final int savings;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.greenSoft,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.green.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        const Icon(Icons.local_offer_rounded, color: AppColors.green, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(TextSpan(children: [
            const TextSpan(text: 'Yay! You\'re saving '),
            TextSpan(text: formatPaise(savings), style: const TextStyle(fontWeight: FontWeight.w800)),
            const TextSpan(text: ' on this order'),
          ])),
        ),
      ]),
    );
  }
}

class _ItemsCard extends StatelessWidget {
  const _ItemsCard({required this.cart});
  final Cart cart;

  @override
  Widget build(BuildContext context) {
    final items = cart.items;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Row(children: [
          IconBubble(Icons.local_shipping_rounded, color: AppColors.primary, size: 36),
          SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Home delivery', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              Text('Shipped by the brand\'s FitKey store partner', style: TextStyle(fontSize: 12, color: AppColors.text2)),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        for (final it in items) _CartLine(item: it),
      ]),
    );
  }
}

class _CartLine extends StatelessWidget {
  const _CartLine({required this.item});
  final CartItem item;

  @override
  Widget build(BuildContext context) {
    final p = item.product;
    final hasMrp = p.originalPricePaise > p.pricePaise;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.line))),
      child: Row(children: [
        Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.line)),
          child: NetImage(p.images.isEmpty ? null : p.images.first,
              fallback: productFallbackImage(p.category), width: 60, height: 60, radius: 11),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.title,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, height: 1.3)),
            const SizedBox(height: 4),
            PriceText(
              price: formatPaise(p.pricePaise * item.quantity),
              mrp: hasMrp ? formatPaise(p.originalPricePaise * item.quantity) : null,
              size: 14,
            ),
          ]),
        ),
        const SizedBox(width: 10),
        QtyStepper(
          qty: item.quantity,
          compact: true,
          max: maxOrderQty(p),
          onChanged: (q) => context.read<Cart>().setQty(p, q),
        ),
      ]),
    );
  }
}

class _BillCard extends StatelessWidget {
  const _BillCard({required this.cart});
  final Cart cart;

  @override
  Widget build(BuildContext context) {
    Widget row(String label, Widget value, {IconData? icon, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            if (icon != null) ...[Icon(icon, size: 18, color: AppColors.text2), const SizedBox(width: 10)],
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: bold ? 15.5 : 13.5,
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                      color: bold ? AppColors.text : AppColors.text2)),
            ),
            value,
          ]),
        );

    return AppCard(
      child: Column(children: [
        row(
          'Item total (MRP)',
          Text(formatPaise(cart.mrpTotalPaise), style: const TextStyle(fontWeight: FontWeight.w700)),
          icon: Icons.receipt_long_rounded,
        ),
        if (cart.savingsPaise > 0)
          row(
            'Product discount',
            Text('− ${formatPaise(cart.savingsPaise)}',
                style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.green)),
            icon: Icons.local_offer_outlined,
          ),
        const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider()),
        row('To pay', Text(formatPaise(cart.totalPaise), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            bold: true),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------

class _OrderPlacedView extends StatelessWidget {
  const _OrderPlacedView({required this.order});
  final MarketplaceOrder order;

  @override
  Widget build(BuildContext context) {
    final cod = order.paymentMethod == 'cod';
    final units = order.items.fold<int>(0, (s, i) => s + i.quantity);
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(children: [
            const Spacer(),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.4, end: 1),
              duration: const Duration(milliseconds: 600),
              curve: Curves.elasticOut,
              builder: (_, s, child) => Transform.scale(scale: s, child: child),
              child: Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.green,
                  boxShadow: AppShadows.glow(AppColors.green),
                ),
                child: const Icon(Icons.check_rounded, color: Colors.white, size: 64),
              ),
            ),
            const SizedBox(height: 28),
            const Text('Order placed!',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
            const SizedBox(height: 8),
            Text(
              cod
                  ? 'Keep ${formatPaise(order.totalAmountPaise)} ready — you\'ll pay when it arrives.'
                  : 'We\'ve received ${formatPaise(order.totalAmountPaise)}. Your order is being prepared.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.text2, fontSize: 14.5, height: 1.45),
            ),
            const SizedBox(height: 24),
            AppCard(
              color: AppColors.bg,
              shadow: false,
              child: Column(children: [
                _kv('Order ID', '#${order.id.substring(0, 8).toUpperCase()}'),
                if (order.items.isNotEmpty) _kv('Items', '$units unit${units == 1 ? '' : 's'}'),
                if (order.trackingNumber != null) _kv('Tracking no.', order.trackingNumber!),
              ]),
            ),
            const Spacer(),
            AppButton(
              label: 'Track my order',
              icon: Icons.local_shipping_rounded,
              onPressed: () => Navigator.of(context)
                  .pushReplacement(MaterialPageRoute(builder: (_) => OrderTrackingScreen(orderId: order.id))),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Continue shopping'),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Text(k, style: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w500)),
          const Spacer(),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Shared store chrome
// ---------------------------------------------------------------------------

/// App-bar cart icon with a live item-count badge.
class CartIconButton extends StatelessWidget {
  const CartIconButton({super.key});

  @override
  Widget build(BuildContext context) {
    final count = context.select<Cart, int>((c) => c.itemCount);
    return IconButton(
      tooltip: 'Cart',
      onPressed: () => push(context, const CartCheckoutScreen()),
      icon: Badge(
        isLabelVisible: count > 0,
        backgroundColor: AppColors.primary,
        label: Text('$count', style: const TextStyle(fontWeight: FontWeight.w800)),
        child: const Icon(Icons.shopping_bag_outlined),
      ),
    );
  }
}

/// Blinkit-style floating "View cart" bar shown while the cart has items.
class FloatingCartBar extends StatelessWidget {
  const FloatingCartBar({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<Cart>();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, a) => SlideTransition(
        position: Tween(begin: const Offset(0, 1.2), end: Offset.zero).animate(a),
        child: child,
      ),
      child: cart.isEmpty
          ? const SizedBox.shrink()
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Tap(
                  onTap: () => push(context, const CartCheckoutScreen()),
                  child: Container(
                    height: 60,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: AppColors.green,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: AppShadows.glow(AppColors.green),
                    ),
                    child: Row(children: [
                      _thumbs(cart.items),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'}',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.85), fontSize: 12, fontWeight: FontWeight.w700)),
                          Row(children: [
                            Text(formatPaise(cart.totalPaise),
                                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                            if (cart.savingsPaise > 0) ...[
                              const SizedBox(width: 6),
                              Text(formatPaise(cart.mrpTotalPaise),
                                  style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.7),
                                      fontSize: 12,
                                      decoration: TextDecoration.lineThrough,
                                      decorationColor: Colors.white70)),
                            ],
                          ]),
                        ]),
                      ),
                      const Text('View cart', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                      const SizedBox(width: 2),
                      const Icon(Icons.chevron_right_rounded, color: Colors.white),
                    ]),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _thumbs(List<CartItem> items) {
    final shown = items.take(3).toList();
    return SizedBox(
      width: 40.0 + (shown.length - 1) * 16,
      height: 40,
      child: Stack(children: [
        for (final (i, it) in shown.indexed)
          Positioned(
            left: i * 16.0,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: NetImage(it.product.images.isEmpty ? null : it.product.images.first,
                  fallback: productFallbackImage(it.product.category), width: 36, height: 36, radius: 8),
            ),
          ),
      ]),
    );
  }
}
