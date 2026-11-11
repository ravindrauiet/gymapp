import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/brd_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';

/// Icon + colours for each partner type (picker cards, About you, Account).
({IconData icon, IconData art, Color color, Color soft, String example}) partnerTypeVisual(PartnerType t) => switch (t) {
      PartnerType.fitnessCentre => (
          icon: Icons.fitness_center_rounded,
          art: Icons.pool_rounded,
          color: AppColors.primary,
          soft: AppColors.primarySoft,
          example: 'Gym · Pool · Yoga · MMA',
        ),
      PartnerType.sportsCentre => (
          icon: Icons.sports_tennis_rounded,
          art: Icons.sports_cricket_rounded,
          color: AppColors.green,
          soft: AppColors.greenSoft,
          example: 'Badminton · Turf · Tennis',
        ),
      PartnerType.trainer => (
          icon: Icons.sports_gymnastics_rounded,
          art: Icons.self_improvement_rounded,
          color: AppColors.purple,
          soft: AppColors.purpleSoft,
          example: 'Coach · Yoga · Physio',
        ),
      PartnerType.clinic => (
          icon: Icons.local_hospital_rounded,
          art: Icons.monitor_heart_rounded,
          color: AppColors.blue,
          soft: AppColors.blueSoft,
          example: 'Doctors · OPD hours',
        ),
      PartnerType.chemist => (
          icon: Icons.local_pharmacy_rounded,
          art: Icons.medication_rounded,
          color: AppColors.teal,
          soft: AppColors.tealSoft,
          example: 'Pharmacy · Delivery',
        ),
      PartnerType.storeSeller => (
          icon: Icons.storefront_rounded,
          art: Icons.shopping_bag_rounded,
          color: AppColors.amber,
          soft: AppColors.amberSoft,
          example: 'Supplements · Gear',
        ),
    };

/// "What are you joining as?" (Partner BRD §2): first question after OTP login. One tap saves the type.
class PartnerTypeScreen extends StatefulWidget {
  const PartnerTypeScreen({super.key});

  @override
  State<PartnerTypeScreen> createState() => _PartnerTypeScreenState();
}

class _PartnerTypeScreenState extends State<PartnerTypeScreen> {
  PartnerType? _saving;

  Future<void> _pick(PartnerType t) async {
    if (_saving != null) return;
    HapticFeedback.selectionClick();
    setState(() => _saving = t);
    try {
      await context.read<PartnerSession>().setPartnerType(t.api);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PartnerSession>();
    final current = PartnerType.parse(session.user?.partnerType);
    final hasName = (session.user?.name ?? '').trim().isNotEmpty;
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        actions: [TextButton(onPressed: session.signOut, child: const Text('Log out'))],
      ),
      body: SafeArea(
        top: false,
        child: CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            sliver: SliverList.list(children: [
              Row(children: [
                Container(
                  width: 28,
                  height: 6,
                  decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(3)),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 10,
                  height: 6,
                  decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(3)),
                ),
                const SizedBox(width: 10),
                const Text('Step 1 of 2',
                    style: TextStyle(color: AppColors.text3, fontSize: 12.5, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 18),
              Text(hasName ? 'Hi ${session.user!.firstName}, what are you joining as?' : 'What are you joining as?',
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6, height: 1.15)),
              const SizedBox(height: 8),
              const Text('Pick one — we\'ll set up the right listing, tools and payouts for you.',
                  style: TextStyle(color: AppColors.text2, fontSize: 15, height: 1.4)),
              const SizedBox(height: 22),
            ]),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.count(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.86,
              children: [
                for (final t in PartnerType.values)
                  _TypeCard(
                    type: t,
                    selected: current == t,
                    busy: _saving == t,
                    disabled: _saving != null && _saving != t,
                    onTap: () => _pick(t),
                  ),
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            sliver: SliverList.list(children: const [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.info_outline_rounded, size: 16, color: AppColors.text3),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Run more than one business? Start with one — you can add the others later from your account.',
                    style: TextStyle(color: AppColors.text3, fontSize: 12.5, height: 1.4),
                  ),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _TypeCard extends StatelessWidget {
  const _TypeCard({
    required this.type,
    required this.selected,
    required this.busy,
    required this.disabled,
    required this.onTap,
  });

  final PartnerType type;
  final bool selected;
  final bool busy;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = partnerTypeVisual(type);
    final on = selected || busy;
    return Semantics(
      button: true,
      selected: on,
      label: '${type.label}. ${type.blurb}',
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: disabled ? 0.45 : 1,
        child: Tap(
          onTap: disabled ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: v.soft,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: on ? v.color : Colors.transparent, width: 2.5),
              boxShadow: on ? AppShadows.glow(v.color) : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(children: [
                // Illustration: two large overlapping glyphs in the type's colour.
                Positioned(
                  right: -18,
                  bottom: -14,
                  child: Icon(v.icon, size: 104, color: v.color.withValues(alpha: 0.13)),
                ),
                Positioned(
                  right: 46,
                  bottom: 40,
                  child: Icon(v.art, size: 40, color: v.color.withValues(alpha: 0.10)),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: v.color,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [BoxShadow(color: v.color.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4))],
                        ),
                        child: Icon(v.icon, color: Colors.white, size: 24),
                      ),
                      const Spacer(),
                      if (busy)
                        SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: v.color))
                      else
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: on ? v.color : Colors.white,
                            border: Border.all(color: on ? v.color : AppColors.line, width: 2),
                          ),
                          child: on ? const Icon(Icons.check_rounded, size: 14, color: Colors.white) : null,
                        ),
                    ]),
                    const Spacer(),
                    Text(type.label, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                    const SizedBox(height: 3),
                    Text(v.example,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: v.color)),
                    const SizedBox(height: 4),
                    Text(type.blurb,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5, color: AppColors.text2, height: 1.3)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
