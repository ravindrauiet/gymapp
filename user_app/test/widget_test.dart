import 'package:fitkey_core/fitkey_core.dart';
import 'package:fitkey_user/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats API time strings', () {
    expect(formatTimeOfDay('06:00:00'), '6:00 AM');
    expect(formatTimeOfDay('18:30:00'), '6:30 PM');
    expect(formatTimeOfDay('00:15:00'), '12:15 AM');
  });

  test('parses a plan from API JSON', () {
    final plan = Plan.fromJson({
      'id': 'p1',
      'code': 'gym_monthly',
      'name': 'FitKey Gym',
      'categories': ['gym', 'yoga_studio'],
      'pricePaise': 149900,
      'durationDays': 30,
      'features': ['All partner gyms'],
      'venueCount': 4,
    });
    expect(plan.categories, ['gym', 'yoga_studio']);
    expect(formatPaise(plan.pricePaise), '₹1,499');
  });

  test('parses a health report', () {
    final r = HealthReport.fromJson({
      'days': 7,
      'attendance': {
        'totalCheckins': 3,
        'uniqueVenues': 1,
        'activeDays': 3,
        'currentStreak': 2,
        'perDay': [
          {'date': '2026-10-07', 'count': 1},
        ],
        'topVenues': [
          {'id': 'v', 'name': 'Iron Paradise', 'visits': 3},
        ],
      },
      'workouts': {
        'count': 2,
        'totalMinutes': 92,
        'totalDistanceKm': 5.2,
        'totalCalories': 400,
        'byType': [
          {'type': 'running', 'count': 1, 'minutes': 32},
        ],
      },
      'weight': {
        'latest': {'weightKg': 71.2, 'loggedOn': '2026-10-08'},
        'changeKg': -1.3,
        'series': [
          {'weightKg': 72.5, 'loggedOn': '2026-09-20'},
          {'weightKg': 71.2, 'loggedOn': '2026-10-08'},
        ],
      },
    });
    expect(r.currentStreak, 2);
    expect(r.checkinsPerDay[DateTime(2026, 10, 7)], 1);
    expect(r.weightSeries.length, 2);
  });
}
