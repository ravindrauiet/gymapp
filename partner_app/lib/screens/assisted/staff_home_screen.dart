// Assisted listing (Partner BRD §8, contract §D): a FitKey employee lists a business on the partner's behalf.
// The employee gets a scoped token for the partner (no password shared), fills the listing, and the partner later
// accepts it with their own OTP. Access ends when the listing goes live.

import 'package:fitkey_core/fitkey_core.dart' show ApiException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../data/brd_api.dart';
import '../../data/models.dart';
import '../../data/types_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../../widgets/status.dart';
import '../listing_types/type_listing_screen.dart';
import '../venue/venue_editor_screen.dart';

class StaffHomeScreen extends StatefulWidget {
  const StaffHomeScreen({super.key});

  @override
  State<StaffHomeScreen> createState() => _StaffHomeScreenState();
}

class _StaffHomeScreenState extends State<StaffHomeScreen> {
  late Future<List<StaffListing>> _listings = _fetch();

  Future<List<StaffListing>> _fetch() => context.read<PartnerSession>().api.staffListings();

  Future<void> _reload() async {
    final f = _fetch();
    setState(() => _listings = f);
    await f.catchError((_) => <StaffListing>[]);
  }

  /// Switches to the partner's scoped token, opens the right listing flow, and switches back afterwards.
  Future<void> _actAndOpen({
    required String phone,
    required String name,
    required PartnerType type,
    String? city,
    String? venueId,
  }) async {
    final session = context.read<PartnerSession>();
    final nav = Navigator.of(context);
    final r = await session.api.createAssistedPartner(phone: phone, name: name, partnerType: type.api, city: city);
    await session.startActingAs(r.actAsToken);
    try {
      Widget screen;
      if (type.isVenue) {
        PartnerVenue? existing;
        if (venueId != null) existing = await session.api.venue(venueId);
        screen = VenueEditorScreen(existing: existing);
      } else {
        screen = TypeListingScreen(type: type);
      }
      await nav.push(MaterialPageRoute(builder: (_) => _ActingFrame(partnerName: name, child: screen)));
    } finally {
      await session.stopActing();
    }
    if (mounted) await _reload();
  }

  Future<void> _continue(StaffListing l) async {
    final phone = l.partnerPhone == null ? null : normalizeIndianMobile(l.partnerPhone!);
    if (phone == null) {
      toast(context, 'Partner phone not available for this listing', error: true);
      return;
    }
    final type = switch (l.entityType) {
      'trainer' => PartnerType.trainer,
      'clinic' => PartnerType.clinic,
      'chemist' => PartnerType.chemist,
      'store' => PartnerType.storeSeller,
      _ => PartnerType.fitnessCentre,
    };
    try {
      await _actAndOpen(
        phone: phone,
        name: l.partnerName ?? l.name,
        type: type,
        venueId: l.entityType == 'venue' ? l.entityId : null,
      );
    } catch (e) {
      if (mounted) {
        toast(
          context,
          e is ApiException && e.statusCode == 403
              ? 'This partner is live — FitKey access has ended. They manage the listing themselves now.'
              : friendlyError(e),
          error: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<PartnerSession>().user;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Assisted listing')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _Hero(name: user?.name),
            const SizedBox(height: 16),
            _NewPartnerForm(onStart: _actAndOpen),
            const SizedBox(height: 16),
            const _RulesCard(),
            const SectionTitle('Listed by you', subtitle: 'Status of every listing you created'),
            FutureBuilder<List<StaffListing>>(
              future: _listings,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Column(children: [
                    SkeletonBox(height: 78, radius: 20),
                    SizedBox(height: 10),
                    SkeletonBox(height: 78, radius: 20),
                  ]);
                }
                if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
                final items = snap.data!;
                if (items.isEmpty) {
                  return const EmptyView(
                    icon: Icons.storefront_rounded,
                    title: 'No listings yet',
                    message: 'Partners you list will appear here with their review status.',
                  );
                }
                return Column(children: [
                  for (final l in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _ListingTile(
                        listing: l,
                        onContinue: l.status.canSubmit || l.status == VenueStatus.submitted ? () => _continue(l) : null,
                      ),
                    ),
                ]);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Wraps the listing flow with a persistent "acting for" strip so the employee always knows whose account it is.
class _ActingFrame extends StatelessWidget {
  const _ActingFrame({required this.partnerName, required this.child});
  final String partnerName;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Material(
        color: AppColors.purple,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              const Icon(Icons.support_agent_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Listing for $partnerName · earnings, members & bank are hidden',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5)),
              ),
            ]),
          ),
        ),
      ),
      Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: child)),
    ]);
  }
}

class _Hero extends StatelessWidget {
  const _Hero({this.name});
  final String? name;

  @override
  Widget build(BuildContext context) => AppCard(
        gradient: AppColors.mansiGradient,
        shadow: false,
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Tag('FITKEY TEAM', solid: true, color: Colors.white24, dense: true),
          const SizedBox(height: 10),
          Text('Hi ${name?.split(' ').first ?? 'there'} 👋',
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          const SizedBox(height: 4),
          const Text(
            'List gyms, studios, trainers, clinics, chemists and stores for partners who need a hand.',
            style: TextStyle(color: Colors.white, height: 1.4, fontWeight: FontWeight.w500),
          ),
        ]),
      );
}

class _RulesCard extends StatelessWidget {
  const _RulesCard();

  @override
  Widget build(BuildContext context) {
    const rules = [
      (Icons.sms_rounded, 'Login is by OTP on the partner\'s own mobile — never ask for or share a password.'),
      (Icons.verified_user_rounded,
          'A listing goes live only after admin approval AND the partner\'s own OTP acceptance of the agreement.'),
      (Icons.visibility_off_rounded, 'You can\'t see the partner\'s earnings, members or bank details.'),
      (Icons.lock_clock_rounded, 'Your access ends automatically when the listing goes live.'),
    ];
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Rules for listing on behalf', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 10),
        for (final (icon, text) in rules)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              IconBubble(icon, color: AppColors.purple, size: 30),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(color: AppColors.text2, fontSize: 13, height: 1.4))),
            ]),
          ),
      ]),
    );
  }
}

class _NewPartnerForm extends StatefulWidget {
  const _NewPartnerForm({required this.onStart});
  final Future<void> Function({
    required String phone,
    required String name,
    required PartnerType type,
    String? city,
    String? venueId,
  }) onStart;

  @override
  State<_NewPartnerForm> createState() => _NewPartnerFormState();
}

class _NewPartnerFormState extends State<_NewPartnerForm> {
  final _form = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _city = TextEditingController();
  PartnerType? _type;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_phone, _name, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _start() async {
    if (!_form.currentState!.validate()) return;
    if (_type == null) return toast(context, 'Choose the partner type', error: true);
    setState(() => _busy = true);
    try {
      await widget.onStart(
        phone: normalizeIndianMobile(_phone.text)!,
        name: _name.text.trim(),
        type: _type!,
        city: _city.text.trim(),
      );
      if (!mounted) return;
      _form.currentState!.reset();
      for (final c in [_phone, _name, _city]) {
        c.clear();
      }
      setState(() => _type = null);
    } catch (e) {
      if (mounted) {
        toast(
          context,
          e is ApiException && e.statusCode == 403
              ? 'Only FitKey staff accounts can list on behalf, and not for partners who are already live.'
              : friendlyError(e),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Row(children: [
            IconBubble(Icons.person_add_alt_1_rounded, color: AppColors.primary, size: 40),
            SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('List on behalf of a partner', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Text('The partner logs in later with this mobile number',
                    style: TextStyle(color: AppColors.text3, fontSize: 12.5)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d+ ]')), LengthLimitingTextInputFormatter(15)],
            validator: (v) => normalizeIndianMobile(v ?? '') == null ? 'Enter a valid 10-digit mobile number' : null,
            decoration: const InputDecoration(
              labelText: 'Partner\'s mobile number',
              prefixText: '+91 ',
              prefixIcon: Icon(Icons.phone_iphone_rounded),
            ),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            validator: (v) => (v ?? '').trim().length < 2 ? 'Enter the partner\'s name' : null,
            decoration: const InputDecoration(labelText: 'Partner\'s name', prefixIcon: Icon(Icons.person_rounded)),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _city,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'City', prefixIcon: Icon(Icons.location_city_rounded)),
          ),
          const SizedBox(height: 14),
          const Text('Partner type', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final t in PartnerType.values)
              ChoiceChip(
                label: Text(t.label),
                selected: _type == t,
                onSelected: (_) => setState(() => _type = t),
              ),
          ]),
          if (_type != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_type!.blurb, style: const TextStyle(color: AppColors.text3, fontSize: 12.5)),
            ),
          const SizedBox(height: 16),
          AppButton(label: 'Start listing', icon: Icons.arrow_forward_rounded, busy: _busy, onPressed: _start),
        ]),
      ),
    );
  }
}

class _ListingTile extends StatelessWidget {
  const _ListingTile({required this.listing, this.onContinue});
  final StaffListing listing;
  final VoidCallback? onContinue;

  static const _icons = {
    'venue': Icons.fitness_center_rounded,
    'trainer': Icons.sports_gymnastics_rounded,
    'clinic': Icons.local_hospital_rounded,
    'chemist': Icons.local_pharmacy_rounded,
    'store': Icons.storefront_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final l = listing;
    final who = [l.partnerName, l.partnerPhone].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    return AppCard(
      onTap: onContinue,
      padding: const EdgeInsets.all(14),
      child: Row(children: [
        IconBubble(_icons[l.entityType] ?? Icons.storefront_rounded, color: statusColor(l.status), size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
            if (who.isNotEmpty)
              Text(who, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              StatusPill(l.status),
              const Tag('LISTED BY YOU', dense: true, color: AppColors.purple),
              if (l.createdAt != null)
                Text(DateFormat('d MMM').format(l.createdAt!),
                    style: const TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w600)),
            ]),
            if (l.status == VenueStatus.approved)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Waiting for the partner\'s OTP acceptance',
                    style: TextStyle(color: AppColors.teal, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
        if (onContinue != null) const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
      ]),
    );
  }
}
