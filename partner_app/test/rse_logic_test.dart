import 'package:fitkey_partner/data/rse_api.dart';
import 'package:fitkey_partner/screens/earn/earn_tab.dart' show EarnPeriod;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = DateTime(2026, 11, 11); // a Wednesday

  group('member status', () {
    test('expired / expiring within 7 days / active', () {
      expect(memberStatusFor(DateTime(2026, 11, 10), today: today), MemberStatus.expired);
      expect(memberStatusFor(DateTime(2026, 11, 11), today: today), MemberStatus.expiring);
      expect(memberStatusFor(DateTime(2026, 11, 18), today: today), MemberStatus.expiring);
      expect(memberStatusFor(DateTime(2026, 11, 19), today: today), MemberStatus.active);
      expect(memberStatusFor(null, today: today), MemberStatus.active);
    });

    test('parses server status, falls back to the renewal date', () {
      expect(VenueMember.fromJson({'name': 'A', 'status': 'expiring'}).status, MemberStatus.expiring);
      expect(VenueMember.fromJson({'name': 'A', 'renewalOn': '2000-01-01'}).status, MemberStatus.expired);
    });
  });

  test('earning per day spreads the price over the plan days', () {
    expect(earningPerDayPaise(300000, DateTime(2026, 11, 1), DateTime(2026, 12, 1)), 10000);
    expect(earningPerDayPaise(300000, null, DateTime(2026, 12, 1)), 0);
    expect(earningPerDayPaise(5000, DateTime(2026, 11, 1), DateTime(2026, 11, 1)), 5000);
  });

  group('money', () {
    test('compact rupees with Indian grouping', () {
      expect(compactRupees(0), '₹0');
      expect(compactRupees(123456), '₹1,235');
      expect(compactRupees(9999900), '₹99,999');
      expect(compactRupees(12345600), '₹1.2L');
      expect(compactRupees(250000000), '₹25L');
      expect(compactRupees(1500000000), '₹1.5Cr');
      expect(compactRupees(-50000), '-₹500');
    });

    test('typed rupees to paise', () {
      expect(rupeesToPaise('1,499'), 149900);
      expect(rupeesToPaise('₹ 99.5'), 9950);
      expect(rupeesToPaise('abc'), isNull);
      expect(rupeesToPaise('-1'), isNull);
    });
  });

  group('sources', () {
    test('member source labels and parsing', () {
      expect(MemberSource.parse('fitkey_pass').label, 'FitKey pass');
      expect(MemberSource.parse('fitkey_direct').label, 'FitKey direct plan');
      expect(MemberSource.parse('fitpass').label, 'Fitpass');
      expect(MemberSource.parse('nonsense'), MemberSource.other);
      expect(MemberSource.manual.any((s) => s.isFitkey), isFalse);
    });

    test('earning source labels', () {
      expect(earningSourceLabel('fitkey_pass'), 'FitKey pass visits');
      expect(earningSourceLabel('walk_in'), 'Self / walk-in');
      expect(earningSourceLabel('self'), 'Self / walk-in');
      expect(earningSourceLabel('x'), 'Other');
    });
  });

  group('checklist summary', () {
    test('BRD example wording', () {
      final c = SetupChecklist.fromJson({
        'percent': 60,
        'missing': [
          {'step': 7, 'label': 'Pricing & FitKey pass'},
          {'step': 9, 'label': 'Documents & bank'},
        ],
      });
      expect(c.summary, 'Listing 60% complete: Pricing and Documents left');
    });

    test('one, three and many missing', () {
      expect(checklistSummary(90, ['Photos']), 'Listing 90% complete: Photos left');
      expect(checklistSummary(40, ['A', 'B', 'C']), 'Listing 40% complete: A, B and C left');
      expect(checklistSummary(10, ['A', 'B', 'C', 'D', 'E']), 'Listing 10% complete: A, B and 3 more left');
      expect(checklistSummary(100, []), 'Listing 100% complete: ready to submit');
    });
  });

  test('period totals from a per-day series', () {
    final days = [
      for (final (d, v) in [('2026-10-31', 100), ('2026-11-02', 200), ('2026-11-09', 300), ('2026-11-11', 400)])
        DayAmount.fromJson({'date': d, 'netPaise': v}),
    ];
    final p = periodTotals(days, now: today);
    expect(p.today, 400);
    expect(p.week, 700); // Mon 9 Nov onwards
    expect(p.month, 900);
  });

  test('earn periods', () {
    expect(EarnPeriod.week.range(today), (DateTime(2026, 11, 9), today));
    expect(EarnPeriod.month.range(today), (DateTime(2026, 11, 1), today));
    expect(EarnPeriod.lastMonth.range(today), (DateTime(2026, 10, 1), DateTime(2026, 10, 31)));
  });

  group('type run flows', () {
    test('chemist order next step', () {
      ChemistOrder o(String status, String fulfilment) =>
          ChemistOrder.fromJson({'id': '1', 'status': status, 'fulfilment': fulfilment});
      expect(o('requested', 'delivery').nextStatus, 'accepted');
      expect(o('packed', 'delivery').nextStatus, 'out_for_delivery');
      expect(o('packed', 'pickup').nextStatus, 'picked_up');
      expect(o('delivered', 'delivery').nextStatus, isNull);
    });

    test('chemist address object is flattened', () {
      final o = ChemistOrder.fromJson({
        'id': '1',
        'address': {'addressLine': '12 MG Road', 'city': 'Pune', 'pincode': '411001'},
      });
      expect(o.address, '12 MG Road, Pune, 411001');
    });

    test('clinic appointment next step', () {
      expect(nextAppointmentStatus('booked'), 'checked_in');
      expect(nextAppointmentStatus('in_consultation'), 'completed');
      expect(nextAppointmentStatus('completed'), isNull);
    });

    test('store return actions', () {
      expect(StoreReturn.fromJson({'itemId': 'i', 'returnStatus': 'requested'}).actions, ['approved', 'rejected']);
      expect(StoreReturn.fromJson({'itemId': 'i', 'returnStatus': 'refunded'}).actions, isEmpty);
    });
  });
}
