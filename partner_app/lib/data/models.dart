// Typed views over the FITKEY partner endpoints.

typedef Json = Map<String, dynamic>;

List<String> _strings(dynamic v) => (v as List? ?? const []).map((e) => e.toString()).toList();
int _int(dynamic v) => v == null ? 0 : (v as num).toInt();
double? _double(dynamic v) => v == null ? null : (v as num).toDouble();

class PartnerUser {
  PartnerUser.fromJson(Json j)
      : id = j['id'],
        phone = j['phone'],
        name = j['name'],
        email = j['email'],
        city = j['city'],
        partnerType = j['partnerType'],
        isFitkeyStaff = j['isFitkeyStaff'] == true,
        partnerGoLiveAt = j['partnerGoLiveAt'] == null ? null : DateTime.tryParse(j['partnerGoLiveAt'].toString()),
        actingStaff = j['actingStaff'];

  final String id;
  final String phone;
  final String? name;
  final String? email;
  final String? city;

  /// fitness_centre | sports_centre | trainer | clinic | chemist | store_seller (null = not chosen yet).
  final String? partnerType;

  /// FitKey employee account (can "List on behalf of a partner", BRD §8).
  final bool isFitkeyStaff;

  /// Founding-partner commission years count from here (null = nothing live yet).
  final DateTime? partnerGoLiveAt;

  /// Name of the FitKey employee currently acting for this partner (assisted listing), else null.
  final String? actingStaff;

  bool get isVenuePartner => partnerType == null || partnerType == 'fitness_centre' || partnerType == 'sports_centre';

  String get firstName => (name ?? 'Partner').split(' ').first;
}

/// Listing status lifecycle (Partner BRD §6.4):
/// draft → submitted → under_review → changes_needed → … → approved (waiting for owner's OTP) → live; or rejected.
enum VenueStatus {
  draft('Draft'),
  submitted('Submitted'),
  underReview('Under review'),
  changesNeeded('Changes needed'),
  approved('Approved'),
  live('Live'),
  rejected('Not approved');

  const VenueStatus(this.label);
  final String label;

  static VenueStatus parse(String? s) => switch (s) {
        'submitted' => submitted,
        'under_review' => underReview,
        'changes_needed' => changesNeeded,
        'approved' => approved,
        'live' => live,
        'rejected' => rejected,
        _ => draft,
      };

  /// Wire value, e.g. `under_review`.
  String get apiValue => switch (this) { underReview => 'under_review', changesNeeded => 'changes_needed', _ => name };

  bool get canSubmit => this == draft || this == rejected || this == changesNeeded;
  bool get canDelete => this == draft || this == rejected;
}

class VenueListItem {
  VenueListItem.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        area = j['area'],
        city = j['city'],
        categories = _strings(j['categories']),
        status = VenueStatus.parse(j['status']),
        reviewNote = j['reviewNote'],
        coverPhoto = j['coverPhoto'],
        todayCheckins = _int(j['todayCheckins']),
        monthCheckins = _int(j['monthCheckins']),
        ratingAvg = _double(j['ratingAvg']),
        ratingCount = _int(j['ratingCount']);

  final String id;
  final String name;
  final String? area;
  final String? city;
  final List<String> categories;
  final VenueStatus status;
  final String? reviewNote;
  final String? coverPhoto;
  final int todayCheckins;
  final int monthCheckins;

  /// Present only when the backend includes rating aggregates in the venue list.
  final double? ratingAvg;
  final int ratingCount;

  String get location => [area, city].whereType<String>().join(', ');
}

/// Full venue as edited in the listing wizard.
class PartnerVenue {
  PartnerVenue({
    this.id,
    this.status = VenueStatus.draft,
    this.reviewNote,
    this.name = '',
    this.description = '',
    List<String>? categories,
    this.address = '',
    this.area = '',
    this.city = '',
    this.latitude,
    this.longitude,
    this.opensAt = '06:00',
    this.closesAt = '22:00',
    List<String>? openDays,
    this.contactPhone = '',
    this.contactEmail = '',
    this.trainerAvailable = false,
    List<String>? equipment,
    List<String>? amenities,
    List<String>? photos,
    this.ratingAvg,
    this.ratingCount = 0,
    // ---- Partner BRD §3 / contract §B (10-step listing) ----
    List<String>? sports,
    this.videoUrl,
    this.fitkeyPassMode = 'all',
    this.passAccepted = false,
    this.monthlyFeePaise,
    this.slotMinutes = 60,
    this.slotCapacity = 20,
    this.passSlotCap,
    this.courts = 1,
    this.autoAcceptBookings = true,
    this.listingStep = 1,
    List<VenueHour>? hours,
    List<PassBlock>? passBlocks,
    List<VenueClosure>? closures,
    this.listedBy,
    this.partnerAcceptedAt,
    this.adminApprovedAt,
    this.submittedAt,
    this.goLiveAt,
  })  : categories = categories ?? [],
        openDays = openDays ?? ['mon', 'tue', 'wed', 'thu', 'fri', 'sat'],
        equipment = equipment ?? [],
        amenities = amenities ?? [],
        photos = photos ?? [],
        sports = sports ?? [],
        hours = hours ?? [],
        passBlocks = passBlocks ?? [],
        closures = closures ?? [];

  factory PartnerVenue.fromJson(Json j) => PartnerVenue(
        id: j['id'],
        status: VenueStatus.parse(j['status']),
        reviewNote: j['reviewNote'],
        name: j['name'] ?? '',
        description: j['description'] ?? '',
        categories: _strings(j['categories']),
        address: j['address'] ?? '',
        area: j['area'] ?? '',
        city: j['city'] ?? '',
        latitude: _double(j['latitude']),
        longitude: _double(j['longitude']),
        opensAt: (j['opensAt'] as String?)?.substring(0, 5) ?? '06:00',
        closesAt: (j['closesAt'] as String?)?.substring(0, 5) ?? '22:00',
        openDays: _strings(j['openDays']),
        contactPhone: j['contactPhone'] ?? '',
        contactEmail: j['contactEmail'] ?? '',
        trainerAvailable: j['trainerAvailable'] ?? false,
        equipment: _strings(j['equipment']),
        amenities: _strings(j['amenities']),
        photos: _strings(j['photos']),
        ratingAvg: _double(j['ratingAvg']),
        ratingCount: _int(j['ratingCount']),
        sports: _strings(j['sports']),
        videoUrl: j['videoUrl'],
        fitkeyPassMode: j['fitkeyPassMode'] == 'blocked' ? 'blocked' : 'all',
        passAccepted: j['passAccepted'] == true,
        monthlyFeePaise: j['monthlyFeePaise'] == null ? null : _int(j['monthlyFeePaise']),
        slotMinutes: j['slotMinutes'] == null ? 60 : _int(j['slotMinutes']),
        slotCapacity: j['slotCapacity'] == null ? 20 : _int(j['slotCapacity']),
        passSlotCap: j['passSlotCap'] == null ? null : _int(j['passSlotCap']),
        courts: j['courts'] == null ? 1 : _int(j['courts']),
        autoAcceptBookings: j['autoAcceptBookings'] != false,
        listingStep: j['listingStep'] == null ? 1 : _int(j['listingStep']),
        hours: [for (final h in (j['hours'] as List? ?? const [])) VenueHour.fromJson(h as Json)],
        passBlocks: [for (final b in (j['passBlocks'] as List? ?? const [])) PassBlock.fromJson(b as Json)],
        closures: [for (final c in (j['closures'] as List? ?? const [])) VenueClosure.fromJson(c as Json)],
        listedBy: j['listedBy'],
        partnerAcceptedAt: _date(j['partnerAcceptedAt']),
        adminApprovedAt: _date(j['adminApprovedAt']),
        submittedAt: _date(j['submittedAt']),
        goLiveAt: _date(j['goLiveAt']),
      );

  String? id;
  VenueStatus status;
  String? reviewNote;
  String name;
  String description;
  List<String> categories;
  String address;
  String area;
  String city;
  double? latitude;
  double? longitude;
  String opensAt; // HH:MM
  String closesAt; // HH:MM
  List<String> openDays;
  String contactPhone;
  String contactEmail;
  bool trainerAvailable;
  List<String> equipment;
  List<String> amenities;
  List<String> photos;

  /// Read-only rating aggregates (members rate venues after visiting).
  final double? ratingAvg;
  final int ratingCount;

  /// badminton | table_tennis | cricket | football | basketball | tennis | squash | skating | swimming
  List<String> sports;

  /// Optional MP4 video tour (server-relative upload URL).
  String? videoUrl;

  /// `all` = FitKey pass users at all open hours, `blocked` = not during [passBlocks].
  String fitkeyPassMode;

  /// Step 7 consent: "I allow FitKey pass users at my venue…".
  bool passAccepted;

  /// Venue's monthly fee; each FitKey-pass check-in pays monthly fee ÷ 30 minus that year's commission.
  int? monthlyFeePaise;
  int slotMinutes;
  int slotCapacity;

  /// Optional separate cap for FitKey-pass users per slot (null = no separate cap).
  int? passSlotCap;

  /// Courts / lanes bookable per slot (sports venues).
  int courts;
  bool autoAcceptBookings;

  /// Furthest wizard step reached (1–10).
  int listingStep;

  /// Opening hours rows; several rows a day = split shift; kind `ladies_only` marks ladies-only windows.
  List<VenueHour> hours;
  List<PassBlock> passBlocks;

  /// Upcoming holidays / closed dates.
  List<VenueClosure> closures;

  /// Read-only listing lifecycle info.
  final String? listedBy;
  final DateTime? partnerAcceptedAt;
  final DateTime? adminApprovedAt;
  final DateTime? submittedAt;
  final DateTime? goLiveAt;

  /// Deep copy, so the listing wizard can edit without touching the original until saved.
  PartnerVenue copy() => PartnerVenue(
        id: id,
        status: status,
        reviewNote: reviewNote,
        name: name,
        description: description,
        categories: List.of(categories),
        address: address,
        area: area,
        city: city,
        latitude: latitude,
        longitude: longitude,
        opensAt: opensAt,
        closesAt: closesAt,
        openDays: List.of(openDays),
        contactPhone: contactPhone,
        contactEmail: contactEmail,
        trainerAvailable: trainerAvailable,
        equipment: List.of(equipment),
        amenities: List.of(amenities),
        photos: List.of(photos),
        ratingAvg: ratingAvg,
        ratingCount: ratingCount,
        sports: List.of(sports),
        videoUrl: videoUrl,
        fitkeyPassMode: fitkeyPassMode,
        passAccepted: passAccepted,
        monthlyFeePaise: monthlyFeePaise,
        slotMinutes: slotMinutes,
        slotCapacity: slotCapacity,
        passSlotCap: passSlotCap,
        courts: courts,
        autoAcceptBookings: autoAcceptBookings,
        listingStep: listingStep,
        hours: [for (final h in hours) h.copy()],
        passBlocks: [for (final b in passBlocks) b.copy()],
        closures: [for (final c in closures) c.copy()],
        listedBy: listedBy,
        partnerAcceptedAt: partnerAcceptedAt,
        adminApprovedAt: adminApprovedAt,
        submittedAt: submittedAt,
        goLiveAt: goLiveAt,
      );

  Json toJson() {
    String? blank(String s) => s.trim().isEmpty ? null : s.trim();
    return {
      'name': name.trim(),
      'description': ?blank(description),
      'categories': categories,
      'address': address.trim(),
      'area': ?blank(area),
      'city': city.trim(),
      'latitude': ?latitude,
      'longitude': ?longitude,
      'opensAt': opensAt,
      'closesAt': closesAt,
      'openDays': openDays,
      'contactPhone': ?blank(contactPhone),
      'contactEmail': ?blank(contactEmail),
      'trainerAvailable': trainerAvailable,
      'equipment': equipment,
      'amenities': amenities,
      'photos': photos,
      'sports': sports,
      'videoUrl': ?videoUrl,
      'fitkeyPassMode': fitkeyPassMode,
      'passAccepted': passAccepted,
      'monthlyFeePaise': ?monthlyFeePaise,
      'slotMinutes': slotMinutes,
      'slotCapacity': slotCapacity,
      'passSlotCap': ?passSlotCap,
      'courts': courts,
      'autoAcceptBookings': autoAcceptBookings,
      'listingStep': listingStep,
      'hours': [for (final h in hours) h.toJson()],
      'passBlocks': [for (final b in passBlocks) b.toJson()],
      'closures': [for (final c in closures) c.toJson()],
    };
  }
}

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();
String _hhmm(dynamic v, String fallback) {
  final s = v?.toString() ?? '';
  return s.length >= 5 ? s.substring(0, 5) : fallback;
}

/// One opening-hours row (contract §B). Times are `HH:MM`, weekday `mon…sun`.
class VenueHour {
  VenueHour({required this.weekday, required this.opensAt, required this.closesAt, this.kind = 'open'});

  VenueHour.fromJson(Json j)
      : weekday = j['weekday'] ?? 'mon',
        opensAt = _hhmm(j['opensAt'], '06:00'),
        closesAt = _hhmm(j['closesAt'], '22:00'),
        kind = j['kind'] == 'ladies_only' ? 'ladies_only' : 'open';

  String weekday;
  String opensAt;
  String closesAt;

  /// `open` | `ladies_only`
  String kind;

  bool get ladiesOnly => kind == 'ladies_only';
  VenueHour copy() => VenueHour(weekday: weekday, opensAt: opensAt, closesAt: closesAt, kind: kind);
  Json toJson() => {'weekday': weekday, 'opensAt': opensAt, 'closesAt': closesAt, 'kind': kind};
}

/// A window when FitKey-pass users are NOT allowed (BRD §4).
class PassBlock {
  PassBlock({this.id, List<String>? days, this.startsAt = '18:00', this.endsAt = '20:00', this.note})
      : days = days ?? ['mon', 'tue', 'wed', 'thu', 'fri'];

  PassBlock.fromJson(Json j)
      : id = j['id'],
        days = _strings(j['days']),
        startsAt = _hhmm(j['startsAt'], '18:00'),
        endsAt = _hhmm(j['endsAt'], '20:00'),
        note = j['note'];

  String? id;
  List<String> days;
  String startsAt;
  String endsAt;
  String? note;

  PassBlock copy() => PassBlock(id: id, days: List.of(days), startsAt: startsAt, endsAt: endsAt, note: note);
  Json toJson() => {
        'id': ?id,
        'days': days,
        'startsAt': startsAt,
        'endsAt': endsAt,
        if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
      };
}

/// Holiday / closed date (whole day when [slotStart] is null) or a blocked time range on that date.
class VenueClosure {
  VenueClosure({this.id, required this.closedOn, this.slotStart, this.slotEnd, this.note});

  VenueClosure.fromJson(Json j)
      : id = j['id'],
        closedOn = (j['closedOn'] ?? '').toString().length >= 10 ? j['closedOn'].toString().substring(0, 10) : '',
        slotStart = j['slotStart'] == null ? null : _hhmm(j['slotStart'], '00:00'),
        slotEnd = j['slotEnd'] == null ? null : _hhmm(j['slotEnd'], '00:00'),
        note = j['note'];

  String? id;

  /// `YYYY-MM-DD`
  String closedOn;
  String? slotStart;
  String? slotEnd;
  String? note;

  bool get wholeDay => slotStart == null;
  VenueClosure copy() => VenueClosure(id: id, closedOn: closedOn, slotStart: slotStart, slotEnd: slotEnd, note: note);
  Json toJson() => {
        'id': ?id,
        'closedOn': closedOn,
        'slotStart': ?slotStart,
        'slotEnd': ?slotEnd,
        if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
      };
}

class CheckinCode {
  CheckinCode.fromJson(Json j)
      : qr = j['qr'],
        otp = j['otp'],
        expiresAt = DateTime.parse(j['expiresAt']).toLocal();

  final String qr;
  final String otp;
  final DateTime expiresAt;
}

class AttendanceEntry {
  AttendanceEntry.fromJson(Json j)
      : id = j['id'],
        checkedInAt = DateTime.parse(j['checkedInAt']).toLocal(),
        method = j['method'],
        memberName = j['memberName'],
        phoneLast4 = j['phoneLast4'],
        planName = j['planName'];

  final String id;
  final DateTime checkedInAt;
  final String method;
  final String? memberName;
  final String? phoneLast4;
  final String? planName;
}

class AttendanceSummary {
  AttendanceSummary.fromJson(Json j)
      : month = j['month'],
        total = _int(j['total']),
        uniqueMembers = _int(j['uniqueMembers']),
        days = [for (final d in j['days'] as List) (date: DateTime.parse(d['date']), count: _int(d['count']))];

  final String month;
  final int total;
  final int uniqueMembers;
  final List<({DateTime date, int count})> days;
}

// ---- Marketplace / Vendor Portal Models ------------------------------------
class VendorProfile {
  VendorProfile.fromJson(Json j)
      : id = j['id'],
        businessName = j['business_name'] ?? j['businessName'] ?? '',
        gstin = j['gstin'],
        bankName = j['bank_name'] ?? j['bankName'] ?? '',
        bankAccountNo = j['bank_account_no'] ?? j['bankAccountNo'] ?? '',
        ifscCode = j['ifsc_code'] ?? j['ifscCode'] ?? '',
        verificationStatus = j['verification_status'] ?? j['verificationStatus'] ?? 'verified',
        commissionRate = _double(j['commission_rate'] ?? j['commissionRate']) ?? 10.0;

  final String id;
  final String businessName;
  final String? gstin;
  final String bankName;
  final String bankAccountNo;
  final String ifscCode;
  final String verificationStatus;
  final double commissionRate;
}

class VendorProduct {
  VendorProduct.fromJson(Json j)
      : id = j['id'],
        title = j['title'],
        brand = j['brand'],
        category = j['category'],
        description = j['description'],
        pricePaise = _int(j['price_paise'] ?? j['pricePaise']),
        originalPricePaise = _int(j['original_price_paise'] ?? j['originalPricePaise']),
        stockQuantity = _int(j['stock_quantity'] ?? j['stockQuantity']),
        images = _strings(j['images']),
        specs = (j['specs'] is Map) ? Map<String, dynamic>.from(j['specs'] as Map) : {};

  final String id;
  final String title;
  final String brand;
  final String category;
  final String description;
  final int pricePaise;
  final int originalPricePaise;
  final int stockQuantity;
  final List<String> images;
  final Map<String, dynamic> specs;
}

class VendorOrder {
  VendorOrder.fromJson(Json j)
      : id = j['id'],
        status = j['status'],
        totalAmountPaise = _int(j['total_amount_paise'] ?? j['totalAmountPaise']),
        paymentMethod = j['payment_method'] ?? j['paymentMethod'],
        paymentStatus = j['payment_status'] ?? j['paymentStatus'],
        trackingNumber = j['tracking_number'] ?? j['trackingNumber'],
        createdAt = DateTime.parse(j['created_at'] ?? j['createdAt']).toLocal(),
        shippingAddress = (j['shipping_address'] is Map)
            ? Map<String, dynamic>.from(j['shipping_address'] as Map)
            : {},
        items = ((j['vendorItems'] ?? j['vendor_items']) as List? ?? const [])
            .map((i) => (title: i['title'] as String, pricePaise: _int(i['pricePaise']), quantity: _int(i['quantity'])))
            .toList();

  final String id;
  final String status;
  final int totalAmountPaise;
  final String paymentMethod;
  final String paymentStatus;
  final String? trackingNumber;
  final DateTime createdAt;
  final Map<String, dynamic> shippingAddress;
  final List<({String title, int pricePaise, int quantity})> items;
}

class CommissionReport {
  CommissionReport.fromJson(Json j)
      : grossRevenuePaise = _int(j['grossRevenuePaise']),
        commissionRatePercent = _double(j['commissionRatePercent']) ?? 10.0,
        commissionPaise = _int(j['commissionPaise']),
        netPayoutPaise = _int(j['netPayoutPaise']),
        ordersCount = _int(j['ordersCount']);

  final int grossRevenuePaise;
  final double commissionRatePercent;
  final int commissionPaise;
  final int netPayoutPaise;
  final int ordersCount;
}

// ---- Partner Trainer Module Models -----------------------------------------
class PartnerTrainerProfile {
  PartnerTrainerProfile.fromJson(Json j)
      : id = j['id'],
        name = j['name'],
        bio = j['bio'],
        photoUrl = j['photo_url'] ?? j['photoUrl'],
        rating = _double(j['rating']) ?? 5.0,
        reviewCount = _int(j['review_count'] ?? j['reviewCount']),
        certifications = _strings(j['certifications']),
        specializations = _strings(j['specializations']),
        trainingModes = _strings(j['training_modes'] ?? j['trainingModes']),
        hourlyRatePaise = _int(j['hourly_rate_paise'] ?? j['hourlyRatePaise']),
        bufferMinutes = _int(j['buffer_minutes'] ?? j['bufferMinutes']),
        verificationStatus = j['verification_status'] ?? j['verificationStatus'] ?? 'verified';

  final String id;
  final String name;
  final String bio;
  final String? photoUrl;
  final double rating;
  final int reviewCount;
  final List<String> certifications;
  final List<String> specializations;
  final List<String> trainingModes;
  final int hourlyRatePaise;
  final int bufferMinutes;
  final String verificationStatus;
}

class TrainerBookingItem {
  TrainerBookingItem.fromJson(Json j)
      : id = j['id'],
        memberName = j['member_name'] ?? j['memberName'] ?? 'Member',
        memberPhone = j['member_phone'] ?? j['memberPhone'] ?? '',
        mode = j['mode'],
        sessionDate = j['session_date'] ?? j['sessionDate'],
        slotTime = j['slot_time'] ?? j['slotTime'],
        amountPaise = _int(j['amount_paise'] ?? j['amountPaise']),
        status = j['status'];

  final String id;
  final String memberName;
  final String memberPhone;
  final String mode;
  final String sessionDate;
  final String slotTime;
  final int amountPaise;
  final String status;
}
