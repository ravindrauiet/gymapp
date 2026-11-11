// Other partner types' listings (contract §H: trainer / clinic / chemist / store) and assisted listing (§D).

import 'brd_api.dart';
import 'models.dart';
import 'partner_api.dart';

/// Validates a 10-digit Indian mobile number (optionally with +91 / 0 prefix). Returns the bare 10 digits or null.
String? normalizeIndianMobile(String input) {
  var d = input.replaceAll(RegExp(r'\D'), '');
  if (d.length == 12 && d.startsWith('91')) d = d.substring(2);
  if (d.length == 11 && d.startsWith('0')) d = d.substring(1);
  return RegExp(r'^[6-9]\d{9}$').hasMatch(d) ? d : null;
}

int _i(Object? v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

/// URL slug for `/partner/listing/{slug}`.
String typeListingSlug(PartnerType t) => switch (t) {
      PartnerType.trainer => 'trainer',
      PartnerType.clinic => 'clinic',
      PartnerType.chemist => 'chemist',
      PartnerType.storeSeller => 'store',
      _ => throw ArgumentError('Venue types use /partner/venues'),
    };

class ChecklistItem {
  ChecklistItem.fromJson(Json j)
      : step = _i(j['step']),
        label = (j['label'] ?? j['message'] ?? '').toString(),
        hint = j['hint']?.toString();
  final int step;
  final String label;
  final String? hint;
}

class TypeChecklist {
  TypeChecklist.fromJson(Json? j)
      : percent = _i(j?['percent']),
        missing = [for (final m in (j?['missing'] as List? ?? const [])) ChecklistItem.fromJson(m as Json)];
  final int percent;
  final List<ChecklistItem> missing;

  bool stepMissing(int step) => missing.any((m) => m.step == step);
}

/// `GET /partner/listing/:type` → `{ listing, checklist, timeline }`. [listing] is the raw camelCase row (null
/// before the first save) — the wizard reads/writes its fields directly.
class TypeListingBundle {
  TypeListingBundle.fromJson(Json j)
      : listing = j['listing'] is Map ? Map<String, dynamic>.from(j['listing'] as Map) : null,
        checklist = TypeChecklist.fromJson(j['checklist'] is Map ? j['checklist'] as Json : null),
        timeline = j['timeline'] is Map ? ListingTimeline.fromJson(j['timeline'] as Json) : null,
        goLiveBlockers = [
          for (final b in (j['goLiveBlockers'] as List? ?? const [])) if (b is Map) ChecklistItem.fromJson(Json.from(b)),
        ];

  final Json? listing;
  final TypeChecklist checklist;
  final ListingTimeline? timeline;

  /// Things that keep an approved listing from going live (e.g. FSSAI not verified yet for food / supplements).
  final List<ChecklistItem> goLiveBlockers;

  String? get id => listing?['id']?.toString();

  /// `listingStatus` on these tables (NULL = legacy live row); `status` accepted as a fallback.
  VenueStatus get status {
    final l = listing;
    if (l == null) return VenueStatus.draft;
    final s = l['listingStatus'] ?? l['status'];
    if (s == null && l['id'] != null && l.containsKey('listingStatus')) return VenueStatus.live;
    return VenueStatus.parse(s?.toString());
  }

  int get listingStep => _i(listing?['listingStep']);
}

class StaffListing {
  StaffListing.fromJson(Json j)
      : entityType = j['entityType'] ?? 'venue',
        entityId = '${j['entityId']}',
        name = j['name'] ?? 'Untitled listing',
        status = VenueStatus.parse(j['status']),
        partnerName = j['partnerName'],
        partnerPhone = j['partnerPhone'],
        createdAt = j['createdAt'] == null ? null : DateTime.tryParse('${j['createdAt']}')?.toLocal();

  final String entityType;
  final String entityId;
  final String name;
  final VenueStatus status;
  final String? partnerName;
  final String? partnerPhone;
  final DateTime? createdAt;
}

extension TypesApi on PartnerApi {
  Future<TypeListingBundle> typeListing(PartnerType t) async =>
      TypeListingBundle.fromJson(await client.get('/partner/listing/${typeListingSlug(t)}'));

  /// Upserts the owner's listing (creates it on the first save). The response may carry only `listing`; the caller
  /// re-reads the bundle when it needs a fresh checklist.
  Future<TypeListingBundle> saveTypeListing(PartnerType t, Json fields) async =>
      TypeListingBundle.fromJson(await client.put('/partner/listing/${typeListingSlug(t)}', fields));

  /// 400 `{ error, missing }` when incomplete (surfaces as ApiException with the server's message).
  Future<TypeListingBundle> submitTypeListing(PartnerType t) async =>
      TypeListingBundle.fromJson(await client.post('/partner/listing/${typeListingSlug(t)}/submit'));

  // ---- Assisted listing (staff) -----------------------------------------------------------------------------

  Future<List<StaffListing>> staffListings() async => [
        for (final l in ((await client.get('/partner/staff/listings'))['listings'] as List? ?? const []))
          StaffListing.fromJson(l as Json),
      ];

  /// Creates (or finds) the partner and returns a scoped JWT to act as them.
  Future<({PartnerUser partner, String actAsToken})> createAssistedPartner({
    required String phone,
    required String name,
    required String partnerType,
    String? city,
  }) async {
    final r = await client.post('/partner/staff/partners', {
      'phone': phone,
      'name': name,
      'partnerType': partnerType,
      if (city != null && city.isNotEmpty) 'city': city,
    });
    return (partner: PartnerUser.fromJson(r['partner'] as Json), actAsToken: r['actAsToken'] as String);
  }
}
