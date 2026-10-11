import 'package:fitkey_partner/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('venue status parsing and rules', () {
    expect(VenueStatus.parse('under_review'), VenueStatus.underReview);
    expect(VenueStatus.parse('live').canSubmit, isFalse);
    expect(VenueStatus.parse('rejected').canSubmit, isTrue);
  });

  test('venue round-trips to the API payload', () {
    final v = PartnerVenue.fromJson({
      'id': 'v1',
      'status': 'draft',
      'name': 'Iron Paradise',
      'categories': ['gym'],
      'address': '12 MG Road',
      'city': 'Bengaluru',
      'opensAt': '06:00:00',
      'closesAt': '22:00:00',
      'openDays': ['mon', 'tue'],
      'photos': ['/api/v1/files/abc'],
    });
    final json = v.toJson();
    expect(json['opensAt'], '06:00');
    expect(json.containsKey('description'), isFalse);
    expect(json['photos'], ['/api/v1/files/abc']);
  });
}
