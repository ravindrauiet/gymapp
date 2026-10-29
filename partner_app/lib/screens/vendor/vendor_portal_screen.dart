import 'package:fitkey_core/fitkey_core.dart' show formatPaise, formatShortDate, formatDateTime, formatDayDate, apiDate;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../data/partner_api.dart';
import '../../data/vendor_trainer_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../notifications/notifications_screen.dart';

part 'vendor_products.dart';
part 'vendor_orders.dart';
part 'vendor_earnings.dart';
part 'vendor_store_profile.dart';

/// FITKEY Partner — seller hub for marketplace vendors: products, orders, earnings and store profile.
class VendorPortalScreen extends StatefulWidget {
  const VendorPortalScreen({super.key});

  @override
  State<VendorPortalScreen> createState() => _VendorPortalScreenState();
}

class _VendorPortalScreenState extends State<VendorPortalScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  late Future<VendorProfile?> _profile;
  late Future<List<VendorSku>> _skus;
  late Future<List<VendorOrderView>> _orders;
  late Future<CommissionReport> _commission;

  PartnerApi get _api => context.read<PartnerSession>().api;

  @override
  void initState() {
    super.initState();
    _profile = _api.vendorProfile();
    _skus = _api.vendorSkus();
    _orders = _api.vendorOrderViews();
    _commission = _api.commissionReport();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reloadProfile() async {
    setState(() => _profile = _api.vendorProfile());
    await _profile.catchError((_) => null);
  }

  Future<void> _reloadSkus() async {
    setState(() => _skus = _api.vendorSkus());
    await _skus.catchError((_) => <VendorSku>[]);
  }

  /// Orders feed both the Orders and Earnings tabs, so they reload together.
  Future<void> _reloadOrders() async {
    setState(() {
      _orders = _api.vendorOrderViews();
      _commission = _api.commissionReport();
    });
    await Future.wait([_orders.catchError((_) => <VendorOrderView>[]), _commission.then((_) {}, onError: (_) {})]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Seller hub'),
        actions: const [PartnerNotificationBell(), SizedBox(width: 6)],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          labelColor: AppColors.text,
          unselectedLabelColor: AppColors.text3,
          indicatorColor: AppColors.primary,
          indicatorSize: TabBarIndicatorSize.label,
          dividerColor: AppColors.line,
          tabs: const [Tab(text: 'Products'), Tab(text: 'Orders'), Tab(text: 'Earnings'), Tab(text: 'Store')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _ProductsTab(
            future: _skus,
            profile: _profile,
            onReload: _reloadSkus,
            onSetupStore: () => _tabs.animateTo(3),
          ),
          _OrdersTab(future: _orders, onReload: _reloadOrders),
          _EarningsTab(orders: _orders, commission: _commission, onReload: _reloadOrders),
          _StoreProfileTab(future: _profile, onSaved: _reloadProfile),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------------

const _categories = <String, (String, IconData)>{
  'supplements': ('Supplements', Icons.science_rounded),
  'apparel': ('Apparel', Icons.checkroom_rounded),
  'wearables': ('Wearables', Icons.watch_rounded),
  'gear': ('Gym gear', Icons.fitness_center_rounded),
};

String _categoryLabel(String c) => _categories[c]?.$1 ?? c;

/// Scrollable body that still supports pull-to-refresh when it is short (empty / error states).
class _RefreshableFill extends StatelessWidget {
  const _RefreshableFill({required this.onRefresh, required this.child});
  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(constraints: BoxConstraints(minHeight: c.maxHeight), child: child),
        ),
      ),
    );
  }
}

/// Rounded input group used by the forms in this module.
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, {this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Row(children: [
          Expanded(
            child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: AppColors.text)),
          ),
          ?trailing,
        ]),
      );
}
