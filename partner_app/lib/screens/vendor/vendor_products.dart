part of 'vendor_portal_screen.dart';

enum _SkuFilter { all, live, low, out, hidden }

extension on _SkuFilter {
  String get label => switch (this) {
        _SkuFilter.all => 'All',
        _SkuFilter.live => 'Live',
        _SkuFilter.low => 'Low stock',
        _SkuFilter.out => 'Sold out',
        _SkuFilter.hidden => 'Hidden',
      };

  bool test(VendorSku s) => switch (this) {
        _SkuFilter.all => true,
        _SkuFilter.live => s.isActive && s.product.stockQuantity > 0,
        _SkuFilter.low => s.product.stockQuantity > 0 && s.product.stockQuantity <= 10,
        _SkuFilter.out => s.product.stockQuantity <= 0,
        _SkuFilter.hidden => !s.isActive,
      };
}

class _ProductsTab extends StatefulWidget {
  const _ProductsTab({required this.future, required this.profile, required this.onReload, required this.onSetupStore});

  final Future<List<VendorSku>> future;
  final Future<VendorProfile?> profile;
  final Future<void> Function() onReload;
  final VoidCallback onSetupStore;

  @override
  State<_ProductsTab> createState() => _ProductsTabState();
}

class _ProductsTabState extends State<_ProductsTab> with AutomaticKeepAliveClientMixin {
  _SkuFilter _filter = _SkuFilter.all;

  @override
  bool get wantKeepAlive => true;

  Future<void> _edit([VendorSku? sku]) async {
    final saved = await showAppSheet<bool>(context, builder: (_) => _ProductEditorSheet(sku: sku));
    if (saved == true && mounted) {
      toast(context, sku == null ? 'Product added to your store' : 'Product updated');
      widget.onReload();
    }
  }

  Future<void> _stock(VendorSku sku) async {
    final saved = await showAppSheet<bool>(context, builder: (_) => _StockSheet(sku: sku));
    if (saved == true && mounted) {
      toast(context, 'Stock updated');
      widget.onReload();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(children: [
      Expanded(
        child: FutureBuilder<List<VendorSku>>(
          future: widget.future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const _GridSkeleton();
            if (snap.hasError) {
              return _RefreshableFill(onRefresh: widget.onReload, child: ErrorView(error: snap.error!, onRetry: widget.onReload));
            }
            final all = snap.data!;
            if (all.isEmpty) {
              return _RefreshableFill(
                onRefresh: widget.onReload,
                child: EmptyView(
                  icon: Icons.inventory_2_rounded,
                  title: 'List your first product',
                  message: 'Products you add appear in the FITKEY member store with your photos, price and stock.',
                  action: SizedBox(
                    width: 220,
                    child: AppButton(label: 'Add product', icon: Icons.add_rounded, onPressed: () => _edit(), height: 48),
                  ),
                ),
              );
            }
            final shown = all.where(_filter.test).toList();
            final live = all.where(_SkuFilter.live.test).length;
            final low = all.where(_SkuFilter.low.test).length;
            final out = all.where(_SkuFilter.out.test).length;
            return RefreshIndicator(
              onRefresh: widget.onReload,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: _StoreSetupBanner(profile: widget.profile, onTap: widget.onSetupStore)),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    sliver: SliverToBoxAdapter(
                      child: Row(children: [
                        Expanded(child: MetricTile(label: 'Live', value: '$live', icon: Icons.storefront_rounded, color: AppColors.green)),
                        const SizedBox(width: 10),
                        Expanded(child: MetricTile(label: 'Low stock', value: '$low', icon: Icons.trending_down_rounded, color: AppColors.amber)),
                        const SizedBox(width: 10),
                        Expanded(child: MetricTile(label: 'Sold out', value: '$out', icon: Icons.remove_shopping_cart_rounded, color: AppColors.red)),
                      ]),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 4),
                      child: ChoiceChips<_SkuFilter>(
                        options: _SkuFilter.values,
                        selected: _filter,
                        onSelected: (f) => setState(() => _filter = f),
                        label: (f) => '${f.label} · ${all.where(f.test).length}',
                      ),
                    ),
                  ),
                  if (shown.isEmpty)
                    SliverToBoxAdapter(
                      child: EmptyView(
                        icon: Icons.filter_alt_off_rounded,
                        title: 'Nothing here',
                        message: 'No products match "${_filter.label}".',
                        action: TextButton(onPressed: () => setState(() => _filter = _SkuFilter.all), child: const Text('Show all')),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      sliver: SliverGrid.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 240,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                          mainAxisExtent: 300,
                        ),
                        itemCount: shown.length,
                        itemBuilder: (_, i) =>
                            _SkuCard(sku: shown[i], onTap: () => _edit(shown[i]), onStock: () => _stock(shown[i])),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
      BottomActionBar(child: AppButton(label: 'Add product', icon: Icons.add_rounded, onPressed: () => _edit())),
    ]);
  }
}

class _StoreSetupBanner extends StatelessWidget {
  const _StoreSetupBanner({required this.profile, required this.onTap});
  final Future<VendorProfile?> profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<VendorProfile?>(
      future: profile,
      builder: (context, snap) {
        final v = snap.data;
        final complete = v != null && v.bankAccountNo.isNotEmpty && v.ifscCode.isNotEmpty;
        if (snap.connectionState != ConnectionState.done || snap.hasError || complete) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: AppCard(
            onTap: onTap,
            color: AppColors.amberSoft,
            shadow: false,
            padding: const EdgeInsets.all(14),
            child: const Row(children: [
              IconBubble(Icons.account_balance_rounded, color: AppColors.amber, bg: Colors.white, size: 40),
              SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Add your payout details', style: TextStyle(fontWeight: FontWeight.w800)),
                  SizedBox(height: 2),
                  Text('Business name and bank account are needed to receive payouts.',
                      style: TextStyle(color: AppColors.text2, fontSize: 12.5)),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.text2),
            ]),
          ),
        );
      },
    );
  }
}

class _SkuCard extends StatelessWidget {
  const _SkuCard({required this.sku, required this.onTap, required this.onStock});
  final VendorSku sku;
  final VoidCallback onTap;
  final VoidCallback onStock;

  @override
  Widget build(BuildContext context) {
    final p = sku.product;
    final soldOut = p.stockQuantity <= 0;
    final dim = soldOut || !sku.isActive;
    return Tap(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(18), boxShadow: AppShadows.card),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: 150,
            child: Stack(fit: StackFit.expand, children: [
              Opacity(
                opacity: dim ? 0.5 : 1,
                child: NetImage(p.images.isEmpty ? null : p.images.first, fallback: productFallbackImage(p.category), height: 150),
              ),
              if (sku.discountPercent > 0)
                Positioned(
                  top: 0,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(7, 6, 7, 7),
                    decoration: const BoxDecoration(
                      color: AppColors.blue,
                      borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                    ),
                    child: Text('${sku.discountPercent}%\nOFF',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800, height: 1.1)),
                  ),
                ),
              if (p.images.length > 1)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Tag('${p.images.length}', icon: Icons.photo_library_rounded, color: AppColors.ink, bg: AppColors.surface, dense: true),
                ),
              Positioned(
                left: 10,
                bottom: 10,
                child: !sku.isActive
                    ? const Tag('HIDDEN', icon: Icons.visibility_off_rounded, color: AppColors.ink, solid: true, dense: true)
                    : soldOut
                        ? const Tag('SOLD OUT', color: AppColors.ink, solid: true, dense: true)
                        : p.stockQuantity <= 10
                            ? Tag('Only ${p.stockQuantity} left', color: AppColors.red, bg: AppColors.surface, dense: true)
                            : const SizedBox.shrink(),
              ),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p.brand} · ${_categoryLabel(p.category)}'.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: AppColors.text3, letterSpacing: 0.6)),
                const SizedBox(height: 3),
                Text(p.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.3)),
                const Spacer(),
                PriceText(
                  price: formatPaise(p.pricePaise),
                  mrp: p.originalPricePaise > p.pricePaise ? formatPaise(p.originalPricePaise) : null,
                  size: 15,
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Icon(Icons.inventory_2_outlined, size: 15, color: soldOut ? AppColors.red : AppColors.text2),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text('${p.stockQuantity} in stock',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700, color: soldOut ? AppColors.red : AppColors.text2)),
                  ),
                  Tap(
                    onTap: onStock,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(9)),
                      child: const Text('Stock',
                          style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: 12)),
                    ),
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

class _GridSkeleton extends StatelessWidget {
  const _GridSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 240,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          mainAxisExtent: 300,
        ),
        itemCount: 6,
        itemBuilder: (_, _) => const SkeletonBox(height: 300, radius: 18),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quick stock sheet
// ---------------------------------------------------------------------------

class _StockSheet extends StatefulWidget {
  const _StockSheet({required this.sku});
  final VendorSku sku;

  @override
  State<_StockSheet> createState() => _StockSheetState();
}

class _StockSheetState extends State<_StockSheet> {
  late final _ctrl = TextEditingController(text: '${widget.sku.product.stockQuantity}');
  bool _busy = false;

  int get _value => int.tryParse(_ctrl.text.trim()) ?? 0;

  void _bump(int by) {
    final v = (_value + by).clamp(0, 99999);
    setState(() => _ctrl.text = '$v');
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await context.read<PartnerSession>().api.saveVendorSku(widget.sku.id, {'stockQuantity': _value});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        toast(context, friendlyError(e), error: true);
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.sku.product;
    Widget bump(String label, int by) => Expanded(
          child: OutlinedButton(onPressed: () => _bump(by), child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800))),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          NetImage(p.images.isEmpty ? null : p.images.first, fallback: productFallbackImage(p.category), width: 52, height: 52, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Update stock', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2)),
            ]),
          ),
        ]),
        const SizedBox(height: 20),
        TextField(
          controller: _ctrl,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
          decoration: const InputDecoration(suffixText: 'units'),
        ),
        const SizedBox(height: 12),
        Row(children: [
          bump('−10', -10),
          const SizedBox(width: 8),
          bump('−1', -1),
          const SizedBox(width: 8),
          bump('+1', 1),
          const SizedBox(width: 8),
          bump('+10', 10),
        ]),
        const SizedBox(height: 10),
        Text(
          _value == 0 ? 'Members will see this product as SOLD OUT.' : 'Members can order up to $_value units.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _value == 0 ? AppColors.red : AppColors.text2, fontSize: 12.5),
        ),
        const SizedBox(height: 18),
        AppButton(label: 'Save stock', onPressed: _save, busy: _busy),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Add / edit product sheet
// ---------------------------------------------------------------------------

class _ProductEditorSheet extends StatefulWidget {
  const _ProductEditorSheet({this.sku});
  final VendorSku? sku;

  @override
  State<_ProductEditorSheet> createState() => _ProductEditorSheetState();
}

class _ProductEditorSheetState extends State<_ProductEditorSheet> {
  static const _maxPhotos = 6;

  final _form = GlobalKey<FormState>();
  final _picker = ImagePicker();
  late final VendorProduct? _p = widget.sku?.product;
  late final _title = TextEditingController(text: _p?.title ?? '');
  late final _brand = TextEditingController(text: _p?.brand ?? '');
  late final _desc = TextEditingController(text: _p?.description ?? '');
  late final _price = TextEditingController(text: _p == null ? '' : _rupees(_p.pricePaise));
  late final _mrp = TextEditingController(text: _p == null ? '' : _rupees(_p.originalPricePaise));
  late final _stock = TextEditingController(text: _p == null ? '' : '${_p.stockQuantity}');
  late String _category = _p?.category ?? 'supplements';
  late final List<String> _photos = [...?_p?.images];
  late bool _active = widget.sku?.isActive ?? true;
  int _uploading = 0;
  bool _busy = false;

  static String _rupees(int paise) => paise % 100 == 0 ? '${paise ~/ 100}' : (paise / 100).toStringAsFixed(2);
  static int? _paise(String s) {
    final v = double.tryParse(s.trim());
    return v == null ? null : (v * 100).round();
  }

  @override
  void dispose() {
    for (final c in [_title, _brand, _desc, _price, _mrp, _stock]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _addPhotos() async {
    final room = _maxPhotos - _photos.length - _uploading;
    if (room <= 0) return;
    final List<XFile> files;
    try {
      files = room == 1
          ? [?await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 82)]
          : await _picker.pickMultiImage(maxWidth: 1600, imageQuality: 82, limit: room);
    } catch (e) {
      if (mounted) toast(context, 'Could not open your photos', error: true);
      return;
    }
    if (!mounted || files.isEmpty) return;
    final api = context.read<PartnerSession>().api;
    for (final f in files.take(room)) {
      setState(() => _uploading++);
      try {
        final url = await api.uploadPicked(f);
        if (mounted) setState(() => _photos.add(url));
      } catch (e) {
        if (mounted) toast(context, friendlyError(e), error: true);
      } finally {
        if (mounted) setState(() => _uploading--);
      }
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_uploading > 0) {
      toast(context, 'Wait for photos to finish uploading', error: true);
      return;
    }
    final price = _paise(_price.text)!;
    final mrp = _mrp.text.trim().isEmpty ? price : _paise(_mrp.text)!;
    final fields = <String, dynamic>{
      'title': _title.text.trim(),
      'brand': _brand.text.trim(),
      'category': _category,
      'description': _desc.text.trim(),
      'pricePaise': price,
      'originalPricePaise': mrp,
      'stockQuantity': int.parse(_stock.text.trim()),
      'images': _photos,
      if (widget.sku != null) 'isActive': _active,
    };
    setState(() => _busy = true);
    try {
      await context.read<PartnerSession>().api.saveVendorSku(widget.sku?.id, fields);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        toast(context, friendlyError(e), error: true);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final price = _paise(_price.text);
    final mrp = _paise(_mrp.text);
    final off = (price != null && mrp != null && mrp > price && mrp > 0) ? ((mrp - price) * 100 / mrp).round() : 0;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.94,
      minChildSize: 0.5,
      maxChildSize: 0.94,
      builder: (context, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
          child: Row(children: [
            Expanded(
              child: Text(widget.sku == null ? 'Add product' : 'Edit product',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
          ]),
        ),
        Expanded(
          child: Form(
            key: _form,
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              children: [
                _FieldLabel('Photos', trailing: Text('${_photos.length}/$_maxPhotos', style: const TextStyle(color: AppColors.text3, fontSize: 12))),
                SizedBox(
                  height: 96,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (var i = 0; i < _photos.length; i++) _photoTile(i),
                      for (var i = 0; i < _uploading; i++)
                        const Padding(
                          padding: EdgeInsets.only(right: 10),
                          child: Shimmer(child: SkeletonBox(width: 96, height: 96, radius: 14)),
                        ),
                      if (_photos.length + _uploading < _maxPhotos)
                        Tap(
                          onTap: _addPhotos,
                          child: Container(
                            width: 96,
                            decoration: BoxDecoration(
                              color: AppColors.primarySoft,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
                            ),
                            child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Icon(Icons.add_a_photo_rounded, color: AppColors.primary),
                              SizedBox(height: 6),
                              Text('Add', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 12)),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                const Text('The first photo is the cover in the member store. Long-press a photo to make it the cover.',
                    style: TextStyle(color: AppColors.text3, fontSize: 11.5)),
                const SizedBox(height: 18),
                const _FieldLabel('Category'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final e in _categories.entries)
                    ChoiceChip(
                      avatar: Icon(e.value.$2, size: 16, color: _category == e.key ? Colors.white : AppColors.text2),
                      label: Text(e.value.$1),
                      selected: _category == e.key,
                      showCheckmark: false,
                      selectedColor: AppColors.ink,
                      labelStyle: TextStyle(
                          fontWeight: FontWeight.w700, color: _category == e.key ? Colors.white : AppColors.text),
                      onSelected: (_) => setState(() => _category = e.key),
                    ),
                ]),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _title,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Product name', hintText: 'e.g. Whey Protein Isolate 1 kg'),
                  validator: (v) => (v ?? '').trim().length < 3 ? 'At least 3 characters' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _brand,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Brand'),
                  validator: (v) => (v ?? '').trim().length < 2 ? 'Enter the brand' : null,
                ),
                const SizedBox(height: 18),
                const _FieldLabel('Pricing'),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: TextFormField(
                      controller: _price,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Selling price', prefixText: '₹ '),
                      validator: (v) => _paise(v ?? '') == null ? 'Enter a price' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _mrp,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'MRP (optional)', prefixText: '₹ '),
                      validator: (v) {
                        if ((v ?? '').trim().isEmpty) return null;
                        final m = _paise(v!);
                        if (m == null) return 'Invalid MRP';
                        final p = _paise(_price.text);
                        return p != null && m < p ? 'MRP below price' : null;
                      },
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                _PricePreview(price: price, mrp: mrp, off: off),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _stock,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Units in stock', suffixText: 'units'),
                  validator: (v) => int.tryParse((v ?? '').trim()) == null ? 'Enter stock (0 if none)' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _desc,
                  maxLines: 4,
                  minLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                      labelText: 'Description', hintText: 'What is it, who is it for, key specs…', alignLabelWithHint: true),
                  validator: (v) => (v ?? '').trim().length < 10 ? 'At least 10 characters' : null,
                ),
                if (widget.sku != null) ...[
                  const SizedBox(height: 12),
                  AppCard(
                    border: true,
                    shadow: false,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _active,
                      onChanged: (v) => setState(() => _active = v),
                      title: const Text('Visible in member store', style: TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(_active ? 'Members can find and buy it' : 'Hidden — members cannot see it',
                          style: const TextStyle(fontSize: 12.5, color: AppColors.text2)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        BottomActionBar(
          child: AppButton(label: widget.sku == null ? 'Publish product' : 'Save changes', onPressed: _save, busy: _busy),
        ),
      ]),
    );
  }

  Widget _photoTile(int i) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: GestureDetector(
        onLongPress: i == 0
            ? null
            : () {
                HapticFeedback.mediumImpact();
                setState(() => _photos.insert(0, _photos.removeAt(i)));
              },
        child: SizedBox(
          width: 96,
          height: 96,
          child: Stack(fit: StackFit.expand, children: [
            NetImage(_photos[i], fallback: productFallbackImage(_category), radius: 14),
            if (i == 0)
              const Positioned(left: 6, bottom: 6, child: Tag('COVER', color: AppColors.ink, solid: true, dense: true)),
            Positioned(
              top: 4,
              right: 4,
              child: Tap(
                onTap: () => setState(() => _photos.removeAt(i)),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded, size: 16, color: AppColors.ink),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Live preview of how the price shows up in the member store.
class _PricePreview extends StatelessWidget {
  const _PricePreview({required this.price, required this.mrp, required this.off});
  final int? price;
  final int? mrp;
  final int off;

  @override
  Widget build(BuildContext context) {
    if (price == null) {
      return const Text('Members see the selling price; add an MRP above it to show a discount.',
          style: TextStyle(color: AppColors.text3, fontSize: 12));
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Text('Store preview  ', style: TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600)),
        Expanded(child: PriceText(price: formatPaise(price!), mrp: off > 0 ? formatPaise(mrp!) : null, size: 15)),
        if (off > 0) Tag('$off% OFF', color: AppColors.blue, dense: true),
        if (off > 0) ...[
          const SizedBox(width: 6),
          Text('Save ${formatPaise(mrp! - price!)}',
              style: const TextStyle(color: AppColors.green, fontSize: 12, fontWeight: FontWeight.w800)),
        ],
      ]),
    );
  }
}
