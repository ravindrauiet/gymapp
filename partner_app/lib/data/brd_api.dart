// Shared Partner-BRD endpoints (docs/partner_brd_contract.md §A, §C, §E): partner profile, commission plan,
// status timeline, agreement OTP, documents, KYC, bank. Feature screens add their own *_api.dart extensions.

import 'models.dart';
import 'partner_api.dart';

int _i(Object? v) => v == null ? 0 : (v as num).toInt();
double _d(Object? v) => v == null ? 0 : (v as num).toDouble();
DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

/// Partner types (BRD §1). Order = the "What are you joining as?" picker.
enum PartnerType {
  fitnessCentre('fitness_centre', 'Fitness centre', 'Gym, swimming pool, yoga / dance / MMA / martial arts studio'),
  sportsCentre('sports_centre', 'Sports centre', 'Badminton, cricket, football, tennis, squash, skating…'),
  trainer('trainer', 'Trainer', 'Gym trainer, yoga master, physio, coach, nutritionist…'),
  clinic('clinic', 'Clinic', 'Speciality clinic with doctors and OPD hours'),
  chemist('chemist', 'Chemist', 'Pharmacy with optional home delivery'),
  storeSeller('store_seller', 'Store seller', 'Supplements, activewear, gym gear, healthy food…');

  const PartnerType(this.api, this.label, this.blurb);
  final String api;
  final String label;
  final String blurb;

  static PartnerType? parse(String? v) => PartnerType.values.where((t) => t.api == v).firstOrNull;

  bool get isVenue => this == fitnessCentre || this == sportsCentre;

  /// entityType used by documents / timeline / agreement endpoints.
  String get entityType => switch (this) {
        fitnessCentre || sportsCentre => 'venue',
        trainer => 'trainer',
        clinic => 'clinic',
        chemist => 'chemist',
        storeSeller => 'store',
      };
}

class CommissionYear {
  CommissionYear.fromJson(Json j)
      : year = _i(j['year']),
        pct = _d(j['pct']),
        label = j['label'] ?? '',
        note = j['note'] ?? '',
        from = _dt(j['from']),
        to = _dt(j['to']),
        current = j['current'] == true;

  final int year;
  final double pct;
  final String label;
  final String note;
  final DateTime? from;
  final DateTime? to;
  final bool current;

  String get pctLabel => pct == pct.roundToDouble() ? '${pct.toInt()}%' : '$pct%';
}

/// Founding-partner commission plan (BRD §5.3).
class CommissionPlan {
  CommissionPlan.fromJson(Json j)
      : standardPct = _d(j['standardPct']),
        goLiveAt = _dt(j['goLiveAt']),
        currentYear = _i(j['currentYear']),
        currentPct = _d(j['currentPct']),
        currentYearEndsOn = _dt(j['currentYearEndsOn']),
        years = [for (final y in (j['years'] as List? ?? const [])) CommissionYear.fromJson(y as Json)],
        message = j['message'] ?? '',
        payoutRule = j['payoutRule'] ?? '';

  /// Offline fallback with the BRD numbers (used before the server answers).
  factory CommissionPlan.fallback() => CommissionPlan.fromJson({
        'standardPct': 5,
        'currentYear': 1,
        'currentPct': 0,
        'years': [
          {'year': 1, 'pct': 0, 'label': 'Year 1', 'note': 'First year free', 'current': true},
          {'year': 2, 'pct': 2.5, 'label': 'Year 2', 'note': 'Founding-partner rate'},
          {'year': 3, 'pct': 5, 'label': 'Year 3 onwards', 'note': 'Standard rate'},
        ],
        'message': 'Our standard commission is 5%. As a FitKey Founding Partner, your first year is free (0%), the '
            'second year is 2.5%, and the standard 5% applies from the third year.',
        'payoutRule': 'For each FitKey pass check-in you are paid your monthly fee ÷ 30, minus that year\'s '
            'commission. FitKey bears the GST on FitKey pass visits.',
      });

  final double standardPct;
  final DateTime? goLiveAt;
  final int currentYear;
  final double currentPct;
  final DateTime? currentYearEndsOn;
  final List<CommissionYear> years;
  final String message;
  final String payoutRule;

  /// Same maths as backend utils/commission.js (for live previews while typing).
  static double pctForYear(int year) => year <= 1 ? 0 : (year == 2 ? 2.5 : 5);

  /// Case 2: FitKey-pass payout per check-in, in paise.
  static int passVisitNetPaise(int monthlyFeePaise, {int year = 1}) {
    final gross = monthlyFeePaise ~/ 30;
    return gross - (gross * pctForYear(year) / 100).round();
  }

  /// Case 1: partner's share of a direct plan sale (price includes 5% GST), in paise.
  static int directSaleNetPaise(int pricePaise, {int year = 1}) {
    final gst = (pricePaise * 5 / 105).round();
    return pricePaise - gst - (pricePaise * pctForYear(year) / 100).round();
  }

  static int gstPartPaise(int pricePaise) => (pricePaise * 5 / 105).round();
}

class ListingFix {
  ListingFix.fromJson(Json j)
      : step = _i(j['step']),
        message = j['message'] ?? '';
  final int step;
  final String message;
}

class TimelineEvent {
  TimelineEvent.fromJson(Json j)
      : status = VenueStatus.parse(j['status']),
        note = j['note'],
        fixes = [for (final f in (j['fixes'] as List? ?? const [])) ListingFix.fromJson(f as Json)],
        at = _dt(j['createdAt']) ?? DateTime.now(),
        actorName = j['actorName'];

  final VenueStatus status;
  final String? note;
  final List<ListingFix> fixes;
  final DateTime at;
  final String? actorName;
}

class ListingTimeline {
  ListingTimeline.fromJson(Json j)
      : events = [for (final e in (j['events'] as List? ?? const [])) TimelineEvent.fromJson(e as Json)],
        reviewTargetHours = j['reviewTargetHours'] == null ? 48 : _i(j['reviewTargetHours']);

  final List<TimelineEvent> events;
  final int reviewTargetHours;

  /// Fixes from the latest "changes needed" event (what the partner must do now).
  List<ListingFix> get openFixes {
    for (final e in events.reversed) {
      if (e.status == VenueStatus.changesNeeded) return e.fixes;
      if (e.status == VenueStatus.submitted) return const [];
    }
    return const [];
  }
}

class PartnerDocument {
  PartnerDocument.fromJson(Json j)
      : id = j['id'],
        docType = j['docType'],
        fileUrl = j['fileUrl'],
        docNumber = j['docNumber'],
        expiresOn = _dt(j['expiresOn']),
        status = j['status'] ?? 'pending',
        reviewNote = j['reviewNote'];

  final String id;
  final String docType;
  final String fileUrl;
  final String? docNumber;
  final DateTime? expiresOn;

  /// pending | verified | rejected
  final String status;
  final String? reviewNote;

  static const labels = {
    'licence': 'Business licence',
    'gst': 'GST certificate',
    'fssai': 'FSSAI licence',
    'drug_licence': 'Drug licence',
    'clinic_registration': 'Clinic registration',
    'doctor_registration': 'Doctor registration',
    'certificate': 'Certificate',
    'achievement': 'Achievement',
    'trademark': 'Brand / trademark proof',
    'other': 'Other document',
  };
  String get label => labels[docType] ?? docType;
}

class PartnerKyc {
  PartnerKyc.fromJson(Json j)
      : method = j['method'],
        aadhaarMasked = j['aadhaarMasked'],
        nameOnId = j['nameOnId'],
        status = j['status'] ?? 'pending',
        verifiedAt = _dt(j['verifiedAt']);

  final String method;
  final String aadhaarMasked;
  final String? nameOnId;
  final String status;
  final DateTime? verifiedAt;
}

class PartnerBank {
  PartnerBank.fromJson(Json j)
      : id = j['id'],
        holderName = j['holderName'] ?? '',
        last4 = j['last4'] ?? '',
        ifsc = j['ifsc'] ?? '',
        bankName = j['bankName'],
        status = j['status'] ?? 'pending',
        verifiedName = j['verifiedName'];

  final String id;
  final String holderName;
  final String last4;
  final String ifsc;
  final String? bankName;

  /// pending | verified | failed
  final String status;
  final String? verifiedName;
}

class PendingAcceptance {
  PendingAcceptance.fromJson(Json j)
      : entityType = j['entityType'],
        entityId = j['entityId'],
        name = j['name'] ?? 'Your listing',
        listedByName = j['listedByName'];

  final String entityType;
  final String entityId;
  final String name;
  final String? listedByName;
}

extension BrdApi on PartnerApi {
  Future<PartnerUser> updatePartnerProfile({String? partnerType, String? name, String? email, String? city}) async =>
      PartnerUser.fromJson((await client.put('/partner/profile', {
        'partnerType': ?partnerType,
        'name': ?name,
        'email': ?email,
        'city': ?city,
      }))['user'] as Json);

  Future<CommissionPlan> commissionPlan() async => CommissionPlan.fromJson(await client.get('/partner/commission-plan'));

  Future<ListingTimeline> listingTimeline(String entityType, String id) async =>
      ListingTimeline.fromJson(await client.get('/partner/listings/$entityType/$id/timeline'));

  /// Sends the agreement OTP to the owner's phone. Returns the dev OTP when the server is in dev mode.
  Future<String?> requestAgreementOtp(String entityType, String entityId) async =>
      (await client.post('/partner/agreement/otp', {'entityType': entityType, 'entityId': entityId}))['devOtp']
          as String?;

  Future<void> acceptAgreement(String entityType, String entityId, String otp) =>
      client.post('/partner/agreement/accept', {'entityType': entityType, 'entityId': entityId, 'otp': otp});

  Future<List<PendingAcceptance>> pendingAcceptance() async =>
      [for (final i in ((await client.get('/partner/pending-acceptance'))['items'] as List)) PendingAcceptance.fromJson(i as Json)];

  Future<List<PartnerDocument>> documents(String entityType, String entityId) async => [
        for (final d in ((await client.get('/partner/documents', query: {'entityType': entityType, 'entityId': entityId}))['documents']
            as List))
          PartnerDocument.fromJson(d as Json),
      ];

  Future<PartnerDocument> addDocument({
    required String entityType,
    required String entityId,
    required String docType,
    required String fileUrl,
    String? docNumber,
    DateTime? expiresOn,
  }) async =>
      PartnerDocument.fromJson((await client.post('/partner/documents', {
        'entityType': entityType,
        'entityId': entityId,
        'docType': docType,
        'fileUrl': fileUrl,
        'docNumber': ?docNumber,
        if (expiresOn != null) 'expiresOn': expiresOn.toIso8601String().substring(0, 10),
      }))['document'] as Json);

  Future<void> deleteDocument(String id) => client.delete('/partner/documents/$id');

  Future<PartnerKyc?> kyc() async {
    final k = (await client.get('/partner/kyc'))['kyc'];
    return k == null ? null : PartnerKyc.fromJson(k as Json);
  }

  /// Only the last 4 Aadhaar digits ever leave the phone (stored as XXXX-XXXX-1234).
  Future<PartnerKyc> submitKyc({required String method, required String aadhaarLast4, required String nameOnId}) async =>
      PartnerKyc.fromJson((await client.post('/partner/kyc', {
        'method': method,
        'aadhaarLast4': aadhaarLast4,
        'nameOnId': nameOnId,
      }))['kyc'] as Json);

  Future<PartnerBank?> bank() async {
    final a = (await client.get('/partner/bank'))['account'];
    return a == null ? null : PartnerBank.fromJson(a as Json);
  }

  Future<PartnerBank> saveBank({required String holderName, required String accountNumber, required String ifsc}) async =>
      PartnerBank.fromJson((await client.post('/partner/bank', {
        'holderName': holderName,
        'accountNumber': accountNumber,
        'ifsc': ifsc.toUpperCase(),
      }))['account'] as Json);
}
