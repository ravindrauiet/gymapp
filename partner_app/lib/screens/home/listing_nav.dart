import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/brd_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../assisted/handover_screen.dart';
import '../assisted/staff_home_screen.dart';
import '../listing_types/type_listing_screen.dart';
import '../venue/venue_editor_screen.dart';

// Entry points into screens owned by other agents (venue editor, type listings, assisted listing), kept in one
// place so their constructors are wired exactly once.

/// Opens the venue listing editor: a new listing when [venueId] is null, else continues that listing (at 1-based [step]).
Future<Widget?> venueEditorFor(BuildContext context, String? venueId, {int? step}) async {
  if (venueId == null) return const VenueEditorScreen();
  try {
    final v = await context.read<PartnerSession>().api.venue(venueId);
    return VenueEditorScreen(existing: v, initialStep: step);
  } catch (e) {
    if (context.mounted) toast(context, friendlyError(e), error: true);
    return null;
  }
}

/// The listing editor for a non-venue partner type (trainer / clinic / chemist / store seller).
Widget typeListingScreen(PartnerType type) => TypeListingScreen(type: type);

/// Staff home ("List on behalf of a partner").
Widget staffHomeScreen() => const StaffHomeScreen();

/// Full-screen assisted-listing handover (owner accepts listings created for them by FitKey staff).
Widget handoverScreen(List<PendingAcceptance> items) => AssistedHandoverScreen(items: items);
