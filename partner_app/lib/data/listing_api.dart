// 10-step venue listing (Partner BRD §3, contract §B): venue + checklist + payout preview, draft save, submit.
// Centre plans (step 7) keep using memberships_api.dart.

import 'package:fitkey_core/fitkey_core.dart' show ApiException;

import 'brd_api.dart';
import 'models.dart';
import 'partner_api.dart';

int _i(Object? v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

/// One unfinished wizard step from the server checklist.
class ChecklistItem {
  const ChecklistItem(this.step, this.label, {this.hint});
  ChecklistItem.fromJson(Json j)
      : step = _i(j['step']),
        label = '${j['label'] ?? ''}',
        hint = j['hint'] as String?;
  final int step;
  final String label;

  /// What to do to finish the step (server-provided).
  final String? hint;
}

/// `checklist: { percent, done:[step], missing:[{step,label}] }` from GET /partner/venues/:id.
class VenueChecklist {
  const VenueChecklist({required this.percent, required this.done, required this.missing});

  VenueChecklist.fromJson(Json j)
      : percent = _i(j['percent']).clamp(0, 100),
        done = [for (final s in (j['done'] as List? ?? const [])) _i(s)],
        missing = [for (final m in (j['missing'] as List? ?? const [])) ChecklistItem.fromJson(m as Json)];

  final int percent;
  final List<int> done;
  final List<ChecklistItem> missing;

  bool get complete => missing.isEmpty;
  bool isDone(int step) => done.contains(step);
}

/// `passPayoutPreview` (backend passVisitPayout): per-check-in gross / commission / net for the current year.
class PassPayoutPreview {
  PassPayoutPreview.fromJson(Json j)
      : grossPaise = _i(j['grossPaise'] ?? j['gross']),
        commissionPct = (j['commissionPct'] as num?)?.toDouble() ?? 0,
        commissionPaise = _i(j['commissionPaise']),
        netPaise = _i(j['netPaise'] ?? j['amountPaise'] ?? j['net']);

  final int grossPaise;
  final double commissionPct;
  final int commissionPaise;
  final int netPaise;
}

/// GET /partner/venues/:id with the listing extras.
class VenueListing {
  VenueListing({required this.venue, this.checklist, this.passPayoutPreview, this.timeline});

  factory VenueListing.fromJson(Json r) {
    final v = (r['venue'] ?? r) as Json;
    Json? map(Object? o) => o is Map<String, dynamic> ? o : null;
    final checklist = map(r['checklist'] ?? v['checklist']);
    final preview = map(r['passPayoutPreview'] ?? v['passPayoutPreview']);
    final timeline = map(r['timeline'] ?? v['timeline']);
    return VenueListing(
      venue: PartnerVenue.fromJson(v),
      checklist: checklist == null ? null : VenueChecklist.fromJson(checklist),
      passPayoutPreview: preview == null ? null : PassPayoutPreview.fromJson(preview),
      timeline: timeline == null ? null : ListingTimeline.fromJson(timeline),
    );
  }

  final PartnerVenue venue;
  final VenueChecklist? checklist;
  final PassPayoutPreview? passPayoutPreview;
  final ListingTimeline? timeline;
}

/// 400 from submit with the steps still missing (`{ error, missing:[{step,label}] }`).
class SubmitIncomplete implements Exception {
  SubmitIncomplete(this.message, this.missing);
  final String message;
  final List<ChecklistItem> missing;
  @override
  String toString() => message;
}

extension ListingApi on PartnerApi {
  Future<VenueListing> venueListing(String id) async => VenueListing.fromJson(await client.get('/partner/venues/$id'));

  /// Creates (no id yet) or updates the venue as a draft. [clear] lists nullable fields the partner removed
  /// (`videoUrl`, `passSlotCap`, `monthlyFeePaise`), sent as explicit nulls.
  Future<PartnerVenue> saveVenueDraft(PartnerVenue v, {Set<String> clear = const {}}) async {
    final body = v.toJson()..addAll({for (final k in clear) k: null});
    // Early drafts: don't send half-typed values the server would reject (address / city are optional on POST,
    // a description of 1–39 chars is a 400). They stay in the wizard and are sent once complete.
    if (v.address.trim().length < 5) body.remove('address');
    if (v.city.trim().length < 2) body.remove('city');
    final desc = v.description.trim().length;
    if (desc > 0 && desc < 40) body.remove('description');
    final r = v.id == null ? await client.post('/partner/venues', body) : await client.put('/partner/venues/${v.id}', body);
    return PartnerVenue.fromJson((r['venue'] ?? r) as Json);
  }

  /// Submits for review. Throws [SubmitIncomplete] when the server lists missing steps (re-fetched from the
  /// checklist, since the API client keeps only the error message).
  Future<PartnerVenue> submitVenueListing(String id) async {
    try {
      final r = await client.post('/partner/venues/$id/submit');
      return PartnerVenue.fromJson((r['venue'] ?? r) as Json);
    } on ApiException catch (e) {
      if (e.statusCode != 400) rethrow;
      List<ChecklistItem> missing = const [];
      try {
        missing = (await venueListing(id)).checklist?.missing ?? const [];
      } catch (_) {}
      throw SubmitIncomplete(e.message, missing);
    }
  }
}
