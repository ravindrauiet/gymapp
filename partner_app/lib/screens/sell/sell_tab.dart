import 'package:flutter/material.dart';

import '../../data/brd_api.dart';
import '../../data/models.dart';
import '../../ui/ui.dart';
import '../events/partner_events_screen.dart';
import '../home/listing_nav.dart';
import '../home/shell.dart';
import '../home/venue_tab_body.dart';
import '../memberships/membership_plans_screen.dart';
import '../notifications/notifications_screen.dart';
import '../ratings/partner_ratings_screen.dart';
import '../trainer/partner_trainer_screen.dart';
import '../vendor/vendor_portal_screen.dart';
import '../venue/venue_overview_screen.dart';

/// Sell (BRD §10.2 / §10.4): the listing, plans & prices, ratings, events and (soon) sponsored listings.
class SellTab extends StatelessWidget {
  const SellTab({super.key});

  @override
  Widget build(BuildContext context) {
    final shell = PartnerShell.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sell'), actions: const [PartnerNotificationBell(), SizedBox(width: 4)]),
      body: shell.type.isVenue
          ? VenueTabBody(builder: _venueTools)
          : ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: _typeTools(context, shell)),
    );
  }

  List<Widget> _venueTools(BuildContext context, VenueListItem v) {
    final shell = PartnerShell.of(context);
    final live = v.status == VenueStatus.live;
    return [
      const TabSection('Your listing'),
      ToolRow(
        icon: Icons.edit_note_rounded,
        color: AppColors.primary,
        title: 'Edit listing',
        subtitle: 'Details, photos, timings, FitKey access, slots',
        onTap: () async {
          final s = await venueEditorFor(context, v.id);
          if (s != null) await shell.open(s);
        },
      ),
      ToolRow(
        icon: Icons.storefront_rounded,
        color: AppColors.green,
        title: 'Listing overview',
        subtitle: '${v.status.label} · how members see ${v.name}',
        onTap: () => shell.open(VenueOverviewScreen(venueId: v.id)),
      ),
      ToolRow(
        icon: Icons.add_business_rounded,
        color: AppColors.teal,
        title: 'Add another venue',
        subtitle: 'A second branch, pool or studio',
        onTap: () async {
          final s = await venueEditorFor(context, null);
          if (s != null) await shell.open(s);
        },
      ),
      const TabSection('Plans & prices'),
      ToolRow(
        icon: Icons.card_membership_rounded,
        color: AppColors.pink,
        title: 'Plans & prices',
        subtitle: 'Day, monthly, yearly plans · pause a plan · offers',
        onTap: () => shell.open(MembershipPlansScreen(venueId: v.id, venueName: v.name)),
      ),
      const TabSection('Reputation & reach'),
      ToolRow(
        icon: Icons.star_rounded,
        color: AppColors.amber,
        title: 'Ratings & reviews',
        subtitle: 'What members say about ${v.name}',
        locked: !live,
        onTap: () => shell.open(PartnerRatingsScreen(venueId: v.id)),
      ),
      ToolRow(
        icon: Icons.event_rounded,
        color: AppColors.purple,
        title: 'Events',
        subtitle: 'Host classes, challenges and meetups',
        locked: !live,
        onTap: () => shell.open(PartnerEventsScreen(venueId: v.id)),
      ),
      const ComingSoonTile(
        icon: Icons.campaign_rounded,
        title: 'Sponsored listing',
        subtitle: 'Get featured at the top of search',
      ),
    ];
  }

  List<Widget> _typeTools(BuildContext context, PartnerShell shell) {
    final t = shell.type;
    return [
      const TabSection('Your listing'),
      ToolRow(
        icon: Icons.edit_note_rounded,
        color: AppColors.primary,
        title: 'Edit listing',
        subtitle: switch (t) {
          PartnerType.trainer => 'Profile, specialities, pricing, availability',
          PartnerType.clinic => 'Doctors, OPD hours, consultation fees',
          PartnerType.chemist => 'Store details, delivery area, licences',
          _ => 'Store details, categories, documents',
        },
        onTap: () => shell.open(typeListingScreen(t)),
      ),
      if (t == PartnerType.trainer) ...[
        const TabSection('Sessions & pricing'),
        ToolRow(
          icon: Icons.badge_rounded,
          color: AppColors.pink,
          title: 'Trainer profile & rates',
          subtitle: 'Session modes, prices and working hours',
          onTap: () => shell.open(const PartnerTrainerScreen(initialTab: 2)),
        ),
      ],
      if (t == PartnerType.storeSeller) ...[
        const TabSection('Catalogue'),
        ToolRow(
          icon: Icons.inventory_2_rounded,
          color: AppColors.teal,
          title: 'Products & prices',
          subtitle: 'SKUs, MRP, discounts and photos',
          onTap: () => shell.open(const VendorPortalScreen()),
        ),
        ToolRow(
          icon: Icons.storefront_rounded,
          color: AppColors.pink,
          title: 'Store profile',
          subtitle: 'Name, logo, shipping and returns policy',
          onTap: () => shell.open(const VendorPortalScreen(initialTab: 3)),
        ),
      ],
      const TabSection('Reputation & reach'),
      ToolRow(
        icon: Icons.star_rounded,
        color: AppColors.amber,
        title: 'Ratings & reviews',
        subtitle: 'What members say about you',
        onTap: () => shell.open(PartnerRatingsScreen(trainer: t == PartnerType.trainer)),
      ),
      if (t == PartnerType.trainer)
        ToolRow(
          icon: Icons.event_rounded,
          color: AppColors.purple,
          title: 'Events',
          subtitle: 'Bootcamps, workshops and group sessions',
          onTap: () => shell.open(const PartnerEventsScreen()),
        ),
      const ComingSoonTile(
        icon: Icons.campaign_rounded,
        title: 'Sponsored listing',
        subtitle: 'Get featured at the top of search',
      ),
    ];
  }
}
