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
        email = j['email'];

  final String id;
  final String phone;
  final String? name;
  final String? email;

  String get firstName => (name ?? 'Partner').split(' ').first;
}

/// Listing status lifecycle (BRD P8): draft → submitted → under_review → live (or rejected).
enum VenueStatus {
  draft('Draft'),
  submitted('Submitted'),
  underReview('Under review'),
  live('Live'),
  rejected('Changes needed');

  const VenueStatus(this.label);
  final String label;

  static VenueStatus parse(String s) => switch (s) {
        'submitted' => submitted,
        'under_review' => underReview,
        'live' => live,
        'rejected' => rejected,
        _ => draft,
      };

  bool get canSubmit => this == draft || this == rejected;
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
        monthCheckins = _int(j['monthCheckins']);

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
  })  : categories = categories ?? [],
        openDays = openDays ?? ['mon', 'tue', 'wed', 'thu', 'fri', 'sat'],
        equipment = equipment ?? [],
        amenities = amenities ?? [],
        photos = photos ?? [];

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
    };
  }
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
