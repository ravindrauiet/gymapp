import 'package:flutter/material.dart';

import '../../data/brd_api.dart';
import '../../data/models.dart';
import '../../ui/ui.dart';

/// Bottom-nav tabs (BRD §9): Home · Run · Sell · Earn · Account.
enum ShellTab { home, run, sell, earn, account }

/// What the tabs need from the signed-in shell: the venue list, navigation helpers, partner type and whether a
/// FitKey employee is listing on behalf of this partner (then earnings, members and bank are hidden).
class PartnerShell extends InheritedWidget {
  const PartnerShell({
    super.key,
    required super.child,
    required this.venues,
    required this.reload,
    required this.open,
    required this.goTab,
    required this.type,
    required this.acting,
  });

  final Future<List<VenueListItem>> venues;
  final Future<void> Function() reload;

  /// Pushes a screen and refreshes the venue list when it closes.
  final Future<void> Function(Widget screen) open;
  final void Function(ShellTab tab) goTab;
  final PartnerType type;
  final bool acting;

  static PartnerShell of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PartnerShell>()!;

  @override
  bool updateShouldNotify(PartnerShell old) => venues != old.venues || type != old.type || acting != old.acting;
}

const lockedMessage = 'Available once your venue is live';

/// Toast text for a locked feature: venues say "venue", other partner types say "listing".
String lockedMessageOf(BuildContext context) {
  final shell = context.getInheritedWidgetOfExactType<PartnerShell>();
  return shell == null || shell.type.isVenue ? lockedMessage : 'Available once your listing is live';
}

/// Opens [build] for a live venue — directly when there's one, via a picker when there are several.
Future<void> forLiveVenue(
  BuildContext context,
  List<VenueListItem> venues, {
  required String title,
  required Widget Function(VenueListItem v) build,
}) async {
  final shell = PartnerShell.of(context);
  final live = venues.where((v) => v.status == VenueStatus.live).toList();
  if (live.isEmpty) {
    toast(context, lockedMessage, icon: Icons.lock_outline_rounded);
    return;
  }
  if (live.length == 1) return shell.open(build(live.first));
  final picked = await pickVenue(context, live, title: title);
  if (picked != null) await shell.open(build(picked));
}

Future<VenueListItem?> pickVenue(BuildContext context, List<VenueListItem> venues, {required String title}) =>
    showAppSheet<VenueListItem>(
      context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                children: [
                  for (final v in venues)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: AppCard(
                        padding: const EdgeInsets.all(10),
                        border: true,
                        shadow: false,
                        onTap: () => Navigator.pop(ctx, v),
                        child: Row(
                          children: [
                            NetImage(
                              v.coverPhoto,
                              fallback: venueVisual(v.categories.firstOrNull ?? '').image,
                              width: 52,
                              height: 52,
                              radius: 12,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    v.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    v.location.isEmpty ? v.status.label : v.location,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

/// Horizontal venue switcher shown at the top of Run / Sell / Earn when the partner has several venues.
class VenueSwitcher extends StatelessWidget {
  const VenueSwitcher({
    super.key,
    required this.venues,
    required this.selected,
    required this.onSelected,
    this.allLabel,
  });

  final List<VenueListItem> venues;
  final String? selected;
  final ValueChanged<String?> onSelected;

  /// When set, an extra "all venues" chip (value null) is shown first.
  final String? allLabel;

  @override
  Widget build(BuildContext context) {
    if (venues.length < 2) return const SizedBox.shrink();
    final options = <String?>[if (allLabel != null) null, for (final v in venues) v.id];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ChoiceChips<String?>(
        options: options,
        selected: selected,
        onSelected: onSelected,
        label: (id) => id == null ? allLabel! : venues.firstWhere((v) => v.id == id).name,
        icon: (id) => id == null
            ? Icons.apps_rounded
            : venues.firstWhere((v) => v.id == id).status == VenueStatus.live
            ? Icons.circle
            : Icons.schedule_rounded,
      ),
    );
  }
}

/// Settings-style row: icon, title, subtitle, chevron (or lock when [locked]).
class ToolRow extends StatelessWidget {
  const ToolRow({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.locked = false,
    this.trailing,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool locked;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        onTap: locked ? () => toast(context, lockedMessageOf(context), icon: Icons.lock_outline_rounded) : onTap,
        padding: const EdgeInsets.all(14),
        child: Opacity(
          opacity: locked ? 0.55 : 1,
          child: Row(
            children: [
              IconBubble(icon, color: locked ? AppColors.text3 : color, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                  ],
                ),
              ),
              trailing ??
                  Icon(
                    locked ? Icons.lock_outline_rounded : Icons.chevron_right_rounded,
                    color: AppColors.text3,
                    size: locked ? 20 : 24,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class QuickAction {
  const QuickAction(this.icon, this.label, this.color, this.onTap, {this.locked = false});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool locked;
}

/// 3-column grid of quick actions; locked tiles are greyed with a lock badge and explain why on tap.
class QuickActionGrid extends StatelessWidget {
  const QuickActionGrid({super.key, required this.actions, this.lockedMessage});

  final List<QuickAction> actions;
  final String? lockedMessage;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.05,
      children: [
        for (final a in actions)
          AppCard(
            onTap: a.locked
                ? () => toast(context, lockedMessage ?? lockedMessageOf(context), icon: Icons.lock_outline_rounded)
                : a.onTap,
            padding: const EdgeInsets.all(10),
            radius: 18,
            child: Stack(
              children: [
                Center(
                  child: Opacity(
                    opacity: a.locked ? 0.45 : 1,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconBubble(a.icon, color: a.locked ? AppColors.text3 : a.color, size: 46),
                        const SizedBox(height: 8),
                        Text(
                          a.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                ),
                if (a.locked)
                  const Positioned(
                    top: 0,
                    right: 0,
                    child: Icon(Icons.lock_rounded, size: 16, color: AppColors.text2, semanticLabel: 'Locked'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Small "Coming soon" card used for features announced in the BRD but not built yet.
class ComingSoonTile extends StatelessWidget {
  const ComingSoonTile({super.key, required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return ToolRow(
      icon: icon,
      color: AppColors.purple,
      title: title,
      subtitle: subtitle,
      onTap: () => toast(context, '$title is coming soon', icon: Icons.upcoming_rounded),
      trailing: const Tag('SOON', color: AppColors.purple, dense: true),
    );
  }
}
