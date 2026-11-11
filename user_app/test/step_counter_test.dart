import 'package:fitkey_user/services/step_counter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('history total counts walks made while the app was closed', () {
    // Baseline only saw 0 steps (app opened after the walk), history recorded 6,200.
    expect(StepCounter.combineSteps(historyToday: 6200, liveSinceRead: 0, baselineToday: 0), 6200);
  });

  test('live sensor steps since the last history read are added', () {
    expect(StepCounter.combineSteps(historyToday: 6200, liveSinceRead: 140, baselineToday: 300), 6340);
  });

  test('a reboot (negative delta) or an absurd jump never corrupts the total', () {
    expect(StepCounter.combineSteps(historyToday: 5000, liveSinceRead: -41000, baselineToday: 0), 5000);
    expect(StepCounter.combineSteps(historyToday: 5000, liveSinceRead: 90000, baselineToday: 0), 5000);
  });

  test('never drops below what the live sensor counted (history not subscribed yet early in the day)', () {
    expect(StepCounter.combineSteps(historyToday: 120, liveSinceRead: 0, baselineToday: 900), 900);
  });

  test('no history (iOS / no Play services) → baseline', () {
    expect(StepCounter.combineSteps(historyToday: null, liveSinceRead: 50, baselineToday: 4321), 4321);
  });
}
