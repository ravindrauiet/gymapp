import 'package:fitkey_core/fitkey_core.dart' show ApiException;
import 'package:fitkey_user/data/booking_api.dart';
import 'package:fitkey_user/data/venue_hours.dart';
import 'package:fitkey_user/screens/checkin/checkin_screen.dart' show memberQrRefreshIn;
import 'package:fitkey_user/widgets/venue_card.dart' show isOpenNow;
import 'package:flutter_test/flutter_test.dart';

// 2026-11-09 is a Monday.
DateTime mon(int h, [int m = 0]) => DateTime(2026, 11, 9, h, m);

const split = [
  OpeningHour(weekday: 'mon', opensAt: '06:00', closesAt: '11:00'),
  OpeningHour(weekday: 'mon', opensAt: '17:00', closesAt: '22:00'),
  OpeningHour(weekday: 'mon', opensAt: '11:00', closesAt: '13:00', kind: 'ladies_only'),
  OpeningHour(weekday: 'tue', opensAt: '06:00', closesAt: '22:00'),
];

void main() {
  group('labels', () {
    test('compact times and ranges', () {
      expect(compactTime('06:00'), '6 AM');
      expect(compactTime('18:30:00'), '6:30 PM');
      expect(compactTime('00:00'), '12 AM');
      expect(compactTime('12:00'), '12 PM');
      expect(timeRangeLabel('18:00', '20:00'), '6–8 PM');
      expect(timeRangeLabel('06:00', '12:00'), '6 AM – 12 PM');
      expect(timeRangeLabel('05:30', '09:00'), '5:30–9 AM');
    });

    test('day ranges', () {
      expect(dayRangeLabel(['mon', 'tue', 'wed', 'thu', 'fri']), 'Mon–Fri');
      expect(dayRangeLabel(weekdayKeys), 'Every day');
      expect(dayRangeLabel(['sat', 'sun']), 'Sat, Sun');
      expect(dayRangeLabel(['fri', 'mon', 'wed']), 'Mon, Wed, Fri');
      expect(dayRangeLabel(['mon', 'tue', 'wed', 'sat']), 'Mon–Wed, Sat');
      expect(dayRangeLabel([]), '');
    });

    test('pass block label matches the server wording', () {
      const b = PassBlock(days: ['mon', 'tue', 'wed', 'thu', 'fri'], startsAt: '18:00', endsAt: '20:00');
      expect(b.label, 'FitKey pass not valid 6–8 PM (Mon–Fri)');
      const every = PassBlock(days: weekdayKeys, startsAt: '07:00', endsAt: '09:00');
      expect(every.label, 'FitKey pass not valid 7–9 AM');
      expect(b.covers(mon(18, 30)), isTrue);
      expect(b.covers(mon(20)), isFalse);
      expect(b.covers(DateTime(2026, 11, 14, 19)), isFalse); // Saturday
    });
  });

  group('open now', () {
    test('split shifts', () {
      expect(openWindowAt(split, mon(7)), isNotNull);
      expect(openWindowAt(split, mon(14)), isNull); // between shifts
      expect(openWindowAt(split, mon(21, 59)), isNotNull);
      expect(openWindowAt(split, mon(22)), isNull);
      expect(openWindowAt(split, mon(5, 59)), isNull);
    });

    test('ladies-only window counts as open and is reported', () {
      final w = openWindowAt(split, mon(12));
      expect(w, isNotNull);
      expect(w!.ladiesOnly, isTrue);
    });

    test('days without hours are closed', () {
      expect(openWindowAt(split, DateTime(2026, 11, 11, 9)), isNull); // Wednesday
    });

    test('window past midnight carries into the next day', () {
      const late = [OpeningHour(weekday: 'mon', opensAt: '20:00', closesAt: '02:00')];
      expect(openWindowAt(late, mon(23)), isNotNull);
      expect(openWindowAt(late, DateTime(2026, 11, 10, 1)), isNotNull); // Tue 1 AM
      expect(openWindowAt(late, DateTime(2026, 11, 10, 3)), isNull);
    });

    test('closures win over weekly hours', () {
      const holiday = [VenueClosure(closedOn: '2026-11-09')];
      expect(openWindowAt(split, mon(7), closures: holiday), isNull);
      const blocked = [VenueClosure(closedOn: '2026-11-09', slotStart: '18:00', slotEnd: '19:00')];
      expect(openWindowAt(split, mon(18, 30), closures: blocked), isNull);
      expect(openWindowAt(split, mon(19, 30), closures: blocked), isNotNull);
    });

    test('isOpenNow prefers hours, falls back to opensAt/closesAt', () {
      expect(isOpenNow('06:00:00', '22:00:00', at: mon(14)), isTrue);
      expect(isOpenNow('06:00:00', '22:00:00', at: mon(14), hours: split), isFalse);
      expect(isOpenNow('06:00:00', '22:00:00', at: mon(18), hours: split), isTrue);
      expect(isOpenNow(null, null, at: mon(18)), isNull);
      expect(isOpenNow('22:00:00', '02:00:00', at: mon(1)), isTrue);
    });

    test('next change label', () {
      expect(nextChangeLabel(split, mon(7)), 'Closes 11 AM');
      expect(nextChangeLabel(split, mon(14)), 'Opens 5 PM');
      expect(nextChangeLabel(split, mon(23)), 'Opens tomorrow 6 AM');
      expect(nextChangeLabel(split, DateTime(2026, 11, 10, 23)), 'Opens Mon 6 AM');
      expect(nextChangeLabel(const [], mon(7)), isNull);
    });
  });

  test('VenueTimings parses the member venue payload', () {
    final t = VenueTimings.fromJson({
      'sports': ['badminton', 'table_tennis'],
      'videoUrl': ' ',
      'slotMinutes': 30,
      'hours': [
        {'weekday': 'mon', 'opensAt': '06:00:00', 'closesAt': '10:00:00', 'kind': 'open'},
        {'weekday': 'mon', 'opensAt': '10:00', 'closesAt': '12:00', 'kind': 'ladies_only'},
      ],
      'passBlocks': [
        {'id': 'b1', 'days': ['sat', 'sun'], 'startsAt': '18:00', 'endsAt': '21:00'},
      ],
      'closures': [
        {'id': 'c2', 'closedOn': '2026-12-25', 'note': 'Christmas'},
        {'id': 'c1', 'closedOn': '2026-11-20T00:00:00.000Z', 'slotStart': '06:00', 'slotEnd': '08:00'},
      ],
    });
    expect(t.sports.map(sportLabel), ['Badminton', 'Table tennis']);
    expect(t.videoUrl, isNull);
    expect(t.slotMinutes, 30);
    expect(t.hours, hasLength(2));
    expect(t.hasLadiesOnly, isTrue);
    expect(t.passBlockLabels, ['FitKey pass not valid 6–9 PM (Sat, Sun)']);
    expect(t.closures.map((c) => c.closedOn), ['2026-11-20', '2026-12-25']);
    expect(t.closures.first.fullDay, isFalse);
    // Server labels win when present.
    expect(VenueTimings.fromJson({'passBlockLabels': ['X'], 'passBlocks': []}).passBlockLabels, ['X']);
  });

  group('booking helpers', () {
    VisitCost cost(String? method) =>
        VisitCost.fromJson({'method': method, 'amount': 0, 'label': '', 'sufficient': true});
    Slot slot(Map<String, dynamic> extra) => Slot.fromJson({
          'start': '18:00',
          'end': '19:00',
          'capacity': 10,
          'booked': 2,
          'left': 8,
          'past': false,
          'available': true,
          ...extra,
        });

    test('pass blocks only stop FitKey-pass payments', () {
      final s = slot({'passBlocked': true});
      expect(slotStateFor(s, cost('coins')), SlotState.passBlocked);
      expect(slotStateFor(s, cost('legacy_pass')), SlotState.passBlocked);
      expect(slotStateFor(s, cost('membership')), SlotState.available);
      expect(slotStateLabel(SlotState.passBlocked, s), 'Pass not valid');
    });

    test('closed, full, pass cap and past slots', () {
      expect(slotStateFor(slot({'blocked': true}), cost('membership')), SlotState.closed);
      expect(slotStateFor(slot({'past': true, 'available': false}), cost('coins')), SlotState.past);
      expect(slotStateFor(slot({'left': 0, 'available': false}), cost('coins')), SlotState.full);
      expect(slotStateFor(slot({'passCap': 2, 'passBooked': 2}), cost('session')), SlotState.passFull);
      expect(slotStateFor(slot({'passCap': 2, 'passBooked': 2}), cost('membership')), SlotState.available);
      expect(slot({'ladiesOnly': true}).ladiesOnly, isTrue);
      expect(slotStateLabel(SlotState.available, slot({'left': 3})), 'Only 3 left');
    });

    test('409 codes map to friendly problems', () {
      final blocked = bookingProblem(ApiException('FitKey pass not valid 6–8 PM at this venue.', statusCode: 409, code: 'PASS_BLOCKED'));
      expect(blocked!.title, 'FitKey pass not valid at this time');
      expect(blocked.message, contains('6–8 PM'));
      expect(bookingProblem(ApiException('x', statusCode: 409, code: 'VENUE_CLOSED'))!.title, 'Closed at this time');
      expect(bookingProblem(ApiException('x', statusCode: 409, code: 'PASS_SLOT_FULL'), venueName: 'Iron Gym')!.message,
          contains('Iron Gym membership'));
      expect(bookingProblem(ApiException('x', statusCode: 409)), isNull);
      expect(bookingProblem(Exception('net')), isNull);
    });

    test('booking status labels', () {
      expect(bookingStatusLabel('requested'), 'Awaiting confirmation');
      expect(bookingStatusLabel('rejected'), 'Declined by venue');
      expect(bookingStatusLabel('booked', canCancel: true), 'Booked');
      expect(bookingStatusLabel('booked'), 'Missed');
      expect(bookingStatusLabel('cancelled', refunded: true), 'Cancelled · refunded');
    });

    test('plan duration, validity and limits labels', () {
      expect(durationLabelOf('hourly'), 'Hourly');
      expect(durationLabelOf('weekly'), 'Weekly');
      expect(durationLabelOf('yearly'), 'Yearly');
      expect(durationLabelOf('annual'), 'Yearly');
      expect(durationLabelOf('day'), 'Day pass');
      expect(planValidityLabel('hourly', 0), '1 hour');
      expect(planValidityLabel('day', 1), '1 day');
      expect(planValidityLabel('weekly', 0), '7 days');
      expect(planValidityLabel('monthly', 30), '30 days');
      expect(planValidityLabel('yearly', 365), '1 year');
      expect(planLimitsLabel(1, 4, 'Mornings only'), '1 visit/day · 4 visits/week · Mornings only');
      expect(planLimitsLabel(null, null, ' '), isNull);
    });

    test('member QR refreshes before it expires', () {
      final now = DateTime(2026, 11, 9, 10);
      expect(memberQrRefreshIn(now.add(const Duration(seconds: 60)), now), const Duration(seconds: 50));
      expect(memberQrRefreshIn(now.add(const Duration(seconds: 3)), now), const Duration(seconds: 5));
    });
  });
}
