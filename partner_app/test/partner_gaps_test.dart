import 'package:fitkey_partner/data/brd_api.dart' show PartnerType;
import 'package:fitkey_partner/data/rse_api.dart';
import 'package:fitkey_partner/screens/earn/earn_tab.dart' show directCollectionNote;
import 'package:fitkey_partner/widgets/listing/documents_bank_step.dart';
import 'package:fitkey_partner/widgets/listing/listing_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('open 24 hours', () {
    test('00:00–23:59 is a whole day (seconds ignored), other ranges are not', () {
      expect(isAllDayRange('00:00', '23:59'), isTrue);
      expect(isAllDayRange('00:00:00', '23:59:00'), isTrue);
      expect(isAllDayRange('00:00', '23:30'), isFalse);
      expect(isAllDayRange('06:00', '23:59'), isFalse);
      expect(Shift.allDay().allDay, isTrue);
      expect(Shift.allDay().start, '00:00');
      expect(Shift.allDay().end, '23:59');
    });

    test('display: "Open 24 hours" instead of "12 AM – 11:59 PM"', () {
      expect(prettyHours('00:00', '23:59'), 'Open 24 hours');
      expect(prettyHours('06:00', '22:00'), '6 AM – 10 PM');
    });

    test('a 24-hour day is valid for the server rule closesAt > opensAt', () {
      expect(validateShifts([Shift.allDay()]), isNull);
      final s = WeekSchedule()..applyToDays(weekdays, [Shift.allDay()]);
      expect(validateSchedule(s), isNull);
      final rows = s.toHours();
      expect(rows, hasLength(7));
      expect(rows.every((h) => h.opensAt == '00:00' && h.closesAt == '23:59'), isTrue);
      expect(s.envelope, (opensAt: '00:00', closesAt: '23:59'));
    });

    test('summaries', () {
      final all = WeekSchedule()..applyToDays(weekdays, [Shift.allDay()]);
      expect(scheduleSummary(all), 'All days · Open 24 hours');

      final mixed = WeekSchedule()..applyToDays(weekdays.take(6), [Shift('06:00', '22:00')]);
      mixed.open['mon'] = [Shift.allDay()];
      expect(isOpen24(mixed.open['mon']!), isTrue);
      expect(isOpen24(mixed.open['tue']!), isFalse);
      expect(scheduleSummary(mixed), 'Mon–Sat · different hours per day (Open 24 hours Mon)');
      expect(scheduleDayLines(mixed).first, 'Mon: Open 24 hours');
      expect(scheduleDayLines(mixed)[1], 'Tue: 6 AM – 10 PM');
    });

    test('ladies-only hours fit inside a 24-hour day', () {
      final s = WeekSchedule()..applyToDays(weekdays, [Shift.allDay()]);
      s.ladies.add(DayWindow(days: ['mon'], start: '10:00', end: '12:00'));
      expect(validateSchedule(s), isNull);
    });
  });

  group('PDF detection', () {
    test('from the URL when it tells', () {
      expect(pdfFromUrl('https://x.test/a/licence.PDF'), isTrue);
      expect(pdfFromUrl('/uploads/licence.pdf?v=2'), isTrue);
      expect(pdfFromUrl('/uploads/photo.jpg'), isFalse);
      expect(pdfFromUrl('/uploads/photo.webp#x'), isFalse);
      expect(pdfFromUrl('/api/v1/files/2b0e1c9a-3c55-4c7c-9b55-1f7b1f0c0d11'), isNull);
    });

    test('from the Content-Type header', () {
      expect(isPdfContentType('application/pdf'), isTrue);
      expect(isPdfContentType('Application/PDF; charset=binary'), isTrue);
      expect(isPdfContentType('application/x-pdf'), isTrue);
      expect(isPdfContentType('image/jpeg'), isFalse);
      expect(isPdfContentType(null), isFalse);
    });
  });

  group('GSTIN (optional)', () {
    test('empty is fine, valid passes, malformed is flagged', () {
      expect(ListingValidators.gstinOptional(''), isNull);
      expect(ListingValidators.gstinOptional(null), isNull);
      expect(ListingValidators.gstinOptional('27AAPFU0939F1ZV'), isNull);
      expect(ListingValidators.gstinOptional('27aapfu0939f1zv'), isNull);
      expect(ListingValidators.gstinOptional('27AAPFU0939F1Z'), isNotNull);
      expect(ListingValidators.gstinOptional('ABCDEFGHIJKLMNO'), isNotNull);
    });
  });

  group('member renewal date', () {
    MemberInput input({DateTime? renewalOn}) => MemberInput(
          name: 'Asha',
          joinedOn: DateTime(2026, 11, 1),
          planLabel: 'Monthly',
          renewalOn: renewalOn,
          source: MemberSource.self,
          pricePaise: 150000,
        );

    test('a cleared renewal date is sent as null on edit (so the server clears it), left out on add', () {
      final edit = input().toJson(edit: true);
      expect(edit.containsKey('renewalOn'), isTrue);
      expect(edit['renewalOn'], isNull);
      expect(input().toJson().containsKey('renewalOn'), isFalse);
      expect(input(renewalOn: DateTime(2026, 12, 1)).toJson(edit: true)['renewalOn'], '2026-12-01');
    });
  });

  group('attendance history', () {
    test('visits per month, newest month first', () {
      final months = visitsPerMonth([
        DateTime(2026, 11, 2),
        DateTime(2026, 11, 9),
        DateTime(2026, 10, 30),
        null,
        DateTime(2025, 12, 31),
      ]);
      expect(months, [(DateTime(2026, 11), 2), (DateTime(2026, 10), 1), (DateTime(2025, 12), 1)]);
    });

    test('only FitKey-pass rows of the member register carry a user id', () {
      expect(memberUserId('fp:7f1c2d4e-0000-4000-8000-000000000001'), '7f1c2d4e-0000-4000-8000-000000000001');
      expect(memberUserId('dm:42'), isNull);
      expect(memberUserId('pm:42'), isNull);
      expect(memberUserId('fp:'), isNull);
    });

    test('history JSON parses', () {
      final h = MemberVisitHistory.fromJson({
        'member': {'id': 'u1', 'name': 'Ravi', 'phoneLast4': '4321'},
        'count': 1,
        'visits': [
          {'id': 'c1', 'checkinDate': '2026-11-10', 'checkedInAt': '2026-11-10T06:15:00Z', 'method': 'qr', 'paidVia': 'coins'},
        ],
      });
      expect(h.name, 'Ravi');
      expect(h.phoneLast4, '4321');
      expect(h.visits.single.date, DateTime(2026, 11, 10));
      expect(h.visits.single.method, 'qr');
    });
  });

  group('trainer calendar', () {
    test('counts booked (not cancelled) sessions and finds a day', () {
      final c = TrainerCalendar.fromJson({
        'maxSessionsPerDay': 2,
        'days': [
          {
            'date': '2026-11-18',
            'sessions': [
              {'status': 'confirmed'},
              {'status': 'cancelled'},
            ],
            'freeSlots': ['07:00', '18:00'],
            'full': false,
          },
          {'date': '2026-11-19', 'sessions': [], 'freeSlots': [], 'full': true},
        ],
      });
      expect(c.maxSessionsPerDay, 2);
      final d = c.dayOf(DateTime(2026, 11, 18))!;
      expect(d.sessions, 1);
      expect(d.freeSlots, ['07:00', '18:00']);
      expect(c.dayOf(DateTime(2026, 11, 19))!.full, isTrue);
      expect(c.dayOf(DateTime(2026, 11, 20)), isNull);
    });
  });

  group('payouts per partner type', () {
    test('trainers, clinics and chemists collect directly; venues and store sellers get payouts', () {
      expect(directCollectionNote(PartnerType.trainer), contains('sessions'));
      expect(directCollectionNote(PartnerType.clinic), contains('consultations'));
      expect(directCollectionNote(PartnerType.chemist), contains('orders'));
      expect(directCollectionNote(PartnerType.storeSeller), isNull);
      expect(directCollectionNote(PartnerType.fitnessCentre), isNull);
    });
  });
}
