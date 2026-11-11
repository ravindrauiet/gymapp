import 'package:flutter/material.dart';

import '../../data/brd_api.dart';
import '../../data/models.dart';
import '../../data/rse_api.dart' show MemberStatus;
import '../../ui/ui.dart';
import '../attendance/attendance_screen.dart';
import '../bookings/partner_bookings_screen.dart';
import '../checkin/checkin_code_screen.dart';
import '../home/shell.dart';
import '../home/venue_tab_body.dart';
import '../notifications/notifications_screen.dart';
import '../trainer/partner_trainer_screen.dart';
import '../vendor/vendor_portal_screen.dart';
import 'member_register_screen.dart';
import 'scan_checkin_screen.dart';
import 'slot_board_screen.dart';
import 'type_run_screens.dart';

/// Run (BRD §10.1 / §10.4): day-to-day operations — members, slots & bookings, check-in & attendance for venues;
/// the partner type's own tools for trainers, clinics, chemists and store sellers.
class RunTab extends StatelessWidget {
  const RunTab({super.key});

  @override
  Widget build(BuildContext context) {
    final shell = PartnerShell.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Run'), actions: const [PartnerNotificationBell(), SizedBox(width: 4)]),
      body: shell.type.isVenue ? VenueTabBody(builder: _venueTools) : _TypeRun(type: shell.type),
    );
  }

  List<Widget> _venueTools(BuildContext context, VenueListItem v) {
    final shell = PartnerShell.of(context);
    final locked = v.status != VenueStatus.live;
    return [
      if (locked) ...[const SizedBox(height: 14), _LockedNote(venue: v)],
      if (!shell.acting) ...[
        const TabSection('Members'),
        ToolRow(
          icon: Icons.groups_rounded,
          color: AppColors.blue,
          title: 'Member register',
          subtitle: 'Plans, renewal dates & sources · FitKey members appear automatically',
          locked: locked,
          onTap: () => shell.open(MemberRegisterScreen(venueId: v.id, venueName: v.name)),
        ),
        ToolRow(
          icon: Icons.autorenew_rounded,
          color: AppColors.pink,
          title: 'Renewals due',
          subtitle: 'Members expiring in the next 7 days',
          locked: locked,
          onTap: () =>
              shell.open(MemberRegisterScreen(venueId: v.id, venueName: v.name, initialStatus: MemberStatus.expiring)),
        ),
      ],
      const TabSection('Slots & bookings'),
      ToolRow(
        icon: Icons.view_timeline_rounded,
        color: AppColors.teal,
        title: 'Slot board',
        subtitle: 'Booked vs available per slot, incl. FitKey pass',
        locked: locked,
        onTap: () => shell.open(SlotBoardScreen(venueId: v.id, venueName: v.name)),
      ),
      ToolRow(
        icon: Icons.pending_actions_rounded,
        color: AppColors.amber,
        title: 'Booking requests',
        subtitle: 'Accept or reject · auto-accept setting',
        locked: locked,
        onTap: () => shell.open(SlotBoardScreen(venueId: v.id, venueName: v.name, initialTab: 1)),
      ),
      ToolRow(
        icon: Icons.block_rounded,
        color: AppColors.red,
        title: 'Block a slot or mark a holiday',
        subtitle: 'Members can\'t book closed slots',
        locked: locked,
        onTap: () => shell.open(SlotBoardScreen(venueId: v.id, venueName: v.name, initialTab: 2)),
      ),
      ToolRow(
        icon: Icons.event_available_rounded,
        color: AppColors.blue,
        title: 'Bookings log',
        subtitle: 'Every booking by day, with how it was paid',
        locked: locked,
        onTap: () => shell.open(PartnerBookingsScreen(venueId: v.id, venueName: v.name)),
      ),
      const TabSection('Check-in & attendance'),
      ToolRow(
        icon: Icons.qr_code_2_rounded,
        color: AppColors.primary,
        title: 'Show venue QR',
        subtitle: 'Members scan it at the front desk',
        locked: locked,
        onTap: () => shell.open(CheckinCodeScreen(venueId: v.id, venueName: v.name)),
      ),
      ToolRow(
        icon: Icons.qr_code_scanner_rounded,
        color: AppColors.ink,
        title: 'Scan member QR',
        subtitle: 'Check a member in from their FitKey app',
        locked: locked,
        onTap: () => shell.open(ScanCheckinScreen(venueId: v.id, venueName: v.name)),
      ),
      ToolRow(
        icon: Icons.insights_rounded,
        color: AppColors.purple,
        title: 'Attendance',
        subtitle: 'Today\'s list and each member\'s history',
        locked: locked,
        onTap: () => shell.open(AttendanceScreen(venueId: v.id, venueName: v.name)),
      ),
    ];
  }
}

class _LockedNote extends StatelessWidget {
  const _LockedNote({required this.venue});
  final VenueListItem venue;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.amberSoft, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          const Icon(Icons.lock_outline_rounded, color: AppColors.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${venue.name} is ${venue.status.label.toLowerCase()}. These tools unlock once it is live.',
              style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.text2),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeRun extends StatelessWidget {
  const _TypeRun({required this.type});
  final PartnerType type;

  @override
  Widget build(BuildContext context) {
    final shell = PartnerShell.of(context);
    final rows = switch (type) {
      PartnerType.trainer => [
        const TabSection('Sessions'),
        ToolRow(
          icon: Icons.calendar_month_rounded,
          color: AppColors.teal,
          title: 'Session calendar & bookings',
          subtitle: 'Day-by-day sessions booked by members',
          onTap: () => shell.open(const PartnerTrainerScreen(initialTab: 1)),
        ),
        ToolRow(
          icon: Icons.groups_rounded,
          color: AppColors.blue,
          title: 'Client list',
          subtitle: 'Everyone you\'ve trained, with sessions and spend',
          onTap: () => shell.open(const TrainerClientsScreen()),
        ),
        ToolRow(
          icon: Icons.dashboard_rounded,
          color: AppColors.purple,
          title: 'Overview',
          subtitle: 'Verification, rating and upcoming sessions',
          onTap: () => shell.open(const PartnerTrainerScreen()),
        ),
      ],
      PartnerType.storeSeller => [
        const TabSection('Orders'),
        ToolRow(
          icon: Icons.receipt_long_rounded,
          color: AppColors.blue,
          title: 'Orders',
          subtitle: 'Pack, dispatch and track',
          onTap: () => shell.open(const VendorPortalScreen(initialTab: 1)),
        ),
        ToolRow(
          icon: Icons.assignment_return_rounded,
          color: AppColors.red,
          title: 'Returns & cancellations',
          subtitle: 'Orders that came back or were cancelled',
          onTap: () => shell.open(const StoreReturnsScreen()),
        ),
        const TabSection('Catalogue'),
        ToolRow(
          icon: Icons.inventory_2_rounded,
          color: AppColors.teal,
          title: 'SKUs',
          subtitle: 'Add and edit products',
          onTap: () => shell.open(const VendorPortalScreen()),
        ),
        ToolRow(
          icon: Icons.stacked_bar_chart_rounded,
          color: AppColors.purple,
          title: 'Stock',
          subtitle: 'Units in stock per SKU',
          onTap: () => shell.open(const StoreStockScreen()),
        ),
        ToolRow(
          icon: Icons.warning_amber_rounded,
          color: AppColors.amber,
          title: 'Low-stock alerts',
          subtitle: 'SKUs with ${StoreStockScreen.lowStockAt} or fewer units',
          onTap: () => shell.open(const StoreStockScreen(lowStockOnly: true)),
        ),
      ],
      PartnerType.clinic => [
        const TabSection('Today'),
        ToolRow(
          icon: Icons.people_alt_rounded,
          color: AppColors.teal,
          title: 'Patient queue',
          subtitle: 'Who is waiting, in token order',
          onTap: () => shell.open(const ClinicAppointmentsScreen(queue: true)),
        ),
        ToolRow(
          icon: Icons.event_note_rounded,
          color: AppColors.blue,
          title: 'Appointments',
          subtitle: 'All bookings by day',
          onTap: () => shell.open(const ClinicAppointmentsScreen()),
        ),
      ],
      PartnerType.chemist => [
        const TabSection('Orders'),
        ToolRow(
          icon: Icons.receipt_long_rounded,
          color: AppColors.blue,
          title: 'Orders',
          subtitle: 'Accept, pack and hand over',
          onTap: () => shell.open(const ChemistOrdersScreen()),
        ),
        ToolRow(
          icon: Icons.local_shipping_rounded,
          color: AppColors.teal,
          title: 'Delivery status',
          subtitle: 'Home deliveries in progress',
          onTap: () => shell.open(const ChemistOrdersScreen(deliveriesOnly: true)),
        ),
      ],
      _ => const <Widget>[],
    };
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: rows);
  }
}
