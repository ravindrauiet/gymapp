part of 'vendor_portal_screen.dart';

class _StoreProfileTab extends StatelessWidget {
  const _StoreProfileTab({required this.future, required this.onSaved});
  final Future<VendorProfile?> future;
  final Future<void> Function() onSaved;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<VendorProfile?>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const SkeletonList(count: 5, itemHeight: 64);
        if (snap.hasError) return _RefreshableFill(onRefresh: onSaved, child: ErrorView(error: snap.error!, onRetry: onSaved));
        // Keyed so the form re-seeds after a save / reload.
        return _StoreProfileForm(key: ValueKey(snap.data?.id ?? 'new'), vendor: snap.data, onSaved: onSaved);
      },
    );
  }
}

class _StoreProfileForm extends StatefulWidget {
  const _StoreProfileForm({super.key, required this.vendor, required this.onSaved});
  final VendorProfile? vendor;
  final Future<void> Function() onSaved;

  @override
  State<_StoreProfileForm> createState() => _StoreProfileFormState();
}

class _StoreProfileFormState extends State<_StoreProfileForm> with AutomaticKeepAliveClientMixin {
  final _form = GlobalKey<FormState>();
  late final _business = TextEditingController(text: widget.vendor?.businessName ?? context.read<PartnerSession>().user?.name ?? '');
  late final _gstin = TextEditingController(text: widget.vendor?.gstin ?? '');
  late final _bank = TextEditingController(text: widget.vendor?.bankName ?? '');
  late final _account = TextEditingController(text: widget.vendor?.bankAccountNo ?? '');
  late final _ifsc = TextEditingController(text: widget.vendor?.ifscCode ?? '');
  bool _busy = false;

  static final _gstinRe = RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$');
  static final _ifscRe = RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$');

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    for (final c in [_business, _gstin, _bank, _account, _ifsc]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final gst = _gstin.text.trim().toUpperCase();
      await context.read<PartnerSession>().api.saveVendorProfile({
        'businessName': _business.text.trim(),
        if (gst.isNotEmpty) 'gstin': gst,
        'bankName': _bank.text.trim(),
        'bankAccountNo': _account.text.trim(),
        'ifscCode': _ifsc.text.trim().toUpperCase(),
      });
      if (!mounted) return;
      toast(context, 'Store profile saved');
      await widget.onSaved();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final v = widget.vendor;
    final status = v?.verificationStatus ?? 'not_started';
    final look = switch (status) {
      'verified' => (
          c: AppColors.green,
          soft: AppColors.greenSoft,
          icon: Icons.verified_rounded,
          title: 'Verified seller',
          body: 'Your products are live in the FITKEY member store.'
        ),
      'rejected' => (
          c: AppColors.red,
          soft: AppColors.redSoft,
          icon: Icons.gpp_bad_rounded,
          title: 'Verification rejected',
          body: 'Check your business and bank details below and save again.'
        ),
      'not_started' => (
          c: AppColors.amber,
          soft: AppColors.amberSoft,
          icon: Icons.storefront_rounded,
          title: 'Set up your store',
          body: 'Add your business and payout details to start selling.'
        ),
      _ => (
          c: AppColors.amber,
          soft: AppColors.amberSoft,
          icon: Icons.hourglass_top_rounded,
          title: 'Verification in progress',
          body: 'We are reviewing your details. You can keep adding products meanwhile.'
        ),
    };

    return Column(children: [
      Expanded(
        child: RefreshIndicator(
          onRefresh: widget.onSaved,
          child: Form(
            key: _form,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                AppCard(
                  color: look.soft,
                  shadow: false,
                  child: Row(children: [
                    IconBubble(look.icon, color: look.c, bg: Colors.white, size: 46),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(look.title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: look.c)),
                        const SizedBox(height: 2),
                        Text(look.body, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
                      ]),
                    ),
                  ]),
                ),
                if (v != null) ...[
                  const SizedBox(height: 12),
                  AppCard(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      const IconBubble(Icons.percent_rounded, color: AppColors.primary, size: 38, iconSize: 19),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text('FITKEY commission on each sale', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      Text('${v.commissionRate % 1 == 0 ? v.commissionRate.toInt() : v.commissionRate}%',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    ]),
                  ),
                ],
                const SectionTitle('Business', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                AppCard(
                  child: Column(children: [
                    TextFormField(
                      controller: _business,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Registered business name', prefixIcon: Icon(Icons.storefront_outlined)),
                      validator: (s) => (s ?? '').trim().length < 2 ? 'Enter your business name' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _gstin,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'GSTIN (optional)',
                        hintText: '22AAAAA0000A1Z5',
                        prefixIcon: Icon(Icons.receipt_long_outlined),
                      ),
                      validator: (s) {
                        final t = (s ?? '').trim().toUpperCase();
                        return t.isEmpty || _gstinRe.hasMatch(t) ? null : 'Enter a valid 15-character GSTIN';
                      },
                    ),
                  ]),
                ),
                const SectionTitle('Payout bank account',
                    subtitle: 'Where FITKEY settles your net payouts', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                AppCard(
                  child: Column(children: [
                    TextFormField(
                      controller: _bank,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Bank name', prefixIcon: Icon(Icons.account_balance_outlined)),
                      validator: (s) => (s ?? '').trim().length < 2 ? 'Enter the bank name' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _account,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: 'Account number', prefixIcon: Icon(Icons.numbers_rounded)),
                      validator: (s) {
                        final t = (s ?? '').trim();
                        return t.length < 9 || t.length > 18 ? 'Account numbers have 9–18 digits' : null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _ifsc,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'IFSC code', hintText: 'HDFC0001234', prefixIcon: Icon(Icons.pin_outlined)),
                      validator: (s) => _ifscRe.hasMatch((s ?? '').trim().toUpperCase()) ? null : 'Enter a valid 11-character IFSC',
                    ),
                  ]),
                ),
                const SizedBox(height: 14),
                const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.text3),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text('Bank details are only used for payouts and are never shown to members.',
                        style: TextStyle(color: AppColors.text3, fontSize: 12)),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
      BottomActionBar(child: AppButton(label: v == null ? 'Create store' : 'Save store profile', onPressed: _save, busy: _busy)),
    ]);
  }
}
