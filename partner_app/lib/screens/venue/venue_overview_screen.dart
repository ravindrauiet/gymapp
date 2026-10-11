import 'package:fitkey_core/fitkey_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../widgets/status.dart';
import '../attendance/attendance_screen.dart';
import '../checkin/checkin_code_screen.dart';
import 'venue_editor_screen.dart';

class VenueOverviewScreen extends StatefulWidget {
  const VenueOverviewScreen({super.key, required this.venueId});

  final String venueId;

  @override
  State<VenueOverviewScreen> createState() => _VenueOverviewScreenState();
}

class _VenueOverviewScreenState extends State<VenueOverviewScreen> {
  late Future<PartnerVenue> _future = _load();
  bool _busy = false;

  Future<PartnerVenue> _load() => context.read<PartnerSession>().api.venue(widget.venueId);

  void _reload() => setState(() => _future = _load());

  Future<void> _submit(PartnerVenue v) async {
    setState(() => _busy = true);
    try {
      await context.read<PartnerSession>().api.submitVenue(v.id!);
      if (mounted) showSnack(context, 'Submitted for review 🎉');
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(PartnerVenue v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${v.name}?'),
        content: const Text('This listing will be removed permanently.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<PartnerSession>().api.deleteVenue(v.id!);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  Future<void> _push(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Venue')),
      body: AsyncView<PartnerVenue>(
        future: _future,
        onRetry: _reload,
        builder: (context, v) {
          final missing = _missing(v);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            children: [
              VenueImage(
                url: v.photos.firstOrNull,
                category: v.categories.firstOrNull,
                height: 180,
                borderRadius: 18,
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: Text(v.name, style: Theme.of(context).textTheme.headlineSmall)),
                StatusPill(v.status),
              ]),
              const SizedBox(height: 4),
              Text([v.address, v.city].where((s) => s.isNotEmpty).join(', '),
                  style: const TextStyle(color: FkColors.textSecondary)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: v.categories.map((c) => CategoryPill(venueCategory(c), dense: true)).toList(),
              ),
              const SizedBox(height: 16),
              StatusTimeline(status: v.status, reviewNote: v.reviewNote),
              const SizedBox(height: 16),
              if (v.status == VenueStatus.live) ...[
                FilledButton.icon(
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('Show check-in QR'),
                  onPressed: () => _push(CheckinCodeScreen(venueId: v.id!, venueName: v.name)),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.insights, color: FkColors.sky),
                  label: const Text('Attendance dashboard'),
                  onPressed: () => _push(AttendanceScreen(venueId: v.id!, venueName: v.name)),
                ),
                const SizedBox(height: 10),
              ],
              if (v.status.canSubmit) ...[
                if (missing.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text('Before submitting: ${missing.join(' · ')}',
                        style: const TextStyle(color: FkColors.orange)),
                  ),
                FilledButton.icon(
                  icon: const Icon(Icons.send),
                  label: Text(_busy ? 'Submitting…' : 'Submit for review'),
                  onPressed: _busy || missing.isNotEmpty ? null : () => _submit(v),
                ),
                const SizedBox(height: 10),
              ],
              OutlinedButton.icon(
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit listing'),
                onPressed: () => _push(VenueEditorScreen(existing: v)),
              ),
              if (v.status.canDelete)
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline, color: FkColors.danger),
                  label: const Text('Delete listing', style: TextStyle(color: FkColors.danger)),
                  onPressed: () => _delete(v),
                ),
              const SectionHeader('Listing details'),
              _detail(Icons.schedule, 'Timings',
                  '${formatTimeOfDay('${v.opensAt}:00')} – ${formatTimeOfDay('${v.closesAt}:00')} · ${v.openDays.length} days/week'),
              _detail(Icons.photo_library_outlined, 'Photos', '${v.photos.length} uploaded'),
              _detail(Icons.sports, 'Trainer', v.trainerAvailable ? 'Available' : 'Not available'),
              _detail(Icons.check_circle_outline, 'Amenities',
                  v.amenities.isEmpty ? 'None added' : v.amenities.map((a) => amenityLabels[a]?.$1 ?? a).join(', ')),
              _detail(Icons.fitness_center, 'Equipment', v.equipment.isEmpty ? 'None added' : v.equipment.join(', ')),
              _detail(Icons.call_outlined, 'Contact',
                  [v.contactPhone, v.contactEmail].where((s) => s.isNotEmpty).join(' · ').ifEmpty('Not added')),
              _detail(Icons.my_location, 'Map location',
                  v.latitude == null ? 'Not pinned' : '${v.latitude!.toStringAsFixed(5)}, ${v.longitude!.toStringAsFixed(5)}'),
            ],
          );
        },
      ),
    );
  }

  List<String> _missing(PartnerVenue v) => [
        if (v.photos.length < 4) 'add ${4 - v.photos.length} more photo${v.photos.length == 3 ? '' : 's'}',
        if (v.categories.isEmpty) 'choose a category',
      ];

  Widget _detail(IconData icon, String title, String value) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: FkColors.textSecondary),
        title: Text(title, style: const TextStyle(fontSize: 12, color: FkColors.textSecondary)),
        subtitle: Text(value, style: const TextStyle(color: FkColors.textPrimary, fontSize: 15)),
      );
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
