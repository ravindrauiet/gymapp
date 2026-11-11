import 'package:fitkey_partner/data/models.dart';
import 'package:fitkey_partner/screens/auth/email_rules.dart';
import 'package:fitkey_partner/widgets/listing/listing_rules.dart';
import 'package:fitkey_partner/widgets/listing/photo_quality.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  group('business email', () {
    test('accepts normal addresses, including what keyboards / autofill produce', () {
      for (final e in [
        'name@gmail.com',
        'Name@Gmail.com',
        'name@gmail.com ',
        ' name@gmail.com',
        'name@gmail. com', // smart punctuation space after "."
        'name@gmail.com​', // zero-width space
        'name @gmail.com', // non-breaking space
        'first.last+gym@outlook.co.in',
        "o'brien@yahoo.in",
        'owner@iron-paradise.fit',
      ]) {
        expect(isValidEmail(e), isTrue, reason: e);
        expect(emailValidator(e), isNull, reason: e);
      }
    });

    test('rejects broken addresses', () {
      for (final e in ['', 'name', 'name@', '@gmail.com', 'name@gmail', 'name@@gmail.com', 'na..me@gmail.com', '.name@gmail.com', 'name@-gmail.com']) {
        expect(isValidEmail(e), isFalse, reason: e);
      }
      expect(emailValidator('', required: false), isNull);
      expect(emailValidator(''), isNotNull);
    });

    test('normalises to trimmed lower case', () {
      expect(normalizeEmail(' Name@Gmail.COM​ '), 'name@gmail.com');
    });

    test('formatter strips spaces while typing and keeps the cursor', () {
      const f = NoWhitespaceFormatter();
      final out = f.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: 'name@gmail. com', selection: TextSelection.collapsed(offset: 12)),
      );
      expect(out.text, 'name@gmail.com');
      expect(out.selection.baseOffset, 11);
    });
  });

  group('time helpers', () {
    test('minutes and pretty labels', () {
      expect(toMinutes('06:30'), 390);
      expect(toMinutes('bad'), -1);
      expect(fromMinutes(1110), '18:30');
      expect(prettyTime('18:00'), '6 PM');
      expect(prettyTime('00:15'), '12:15 AM');
      expect(prettyDays(['mon', 'tue', 'wed', 'thu', 'fri']), 'Mon–Fri');
      expect(prettyDays(weekdays), 'All days');
      expect(prettyDays(['sat', 'sun']), 'Weekends');
      expect(prettyDays(['mon', 'wed']), 'Mon, Wed');
    });
  });

  group('hours validation', () {
    test('split shift ok, overlap and reversed rejected', () {
      expect(validateShifts([Shift('06:00', '11:00'), Shift('16:00', '22:00')]), isNull);
      expect(validateShifts([Shift('06:00', '12:00'), Shift('11:00', '22:00')]), contains('overlap'));
      expect(validateShifts([Shift('22:00', '06:00')]), contains('after'));
    });

    test('schedule needs open days and ladies-only inside open hours', () {
      final s = WeekSchedule();
      expect(validateSchedule(s), 'Select the days you are open');
      s.applyToDays(['mon', 'tue'], [Shift('06:00', '12:00'), Shift('16:00', '21:00')]);
      expect(validateSchedule(s), isNull);
      s.ladies.add(DayWindow(days: ['mon'], start: '10:00', end: '12:00'));
      expect(validateSchedule(s), isNull);
      s.ladies.first.end = '13:00'; // runs into the break
      expect(validateSchedule(s), contains('outside your open hours'));
    });

    test('pass blocks required only in blocked mode', () {
      expect(validatePassBlocks('all', []), isNull);
      expect(validatePassBlocks('blocked', []), isNotNull);
      expect(validatePassBlocks('blocked', [PassBlock(startsAt: '18:00', endsAt: '20:00')]), isNull);
      expect(validatePassBlocks('blocked', [PassBlock(days: [], startsAt: '18:00', endsAt: '20:00')]), isNotNull);
      expect(validatePassBlocks('blocked', [PassBlock(startsAt: '20:00', endsAt: '18:00')]), isNotNull);
      expect(passBlockLabel(PassBlock(startsAt: '18:00', endsAt: '20:00')), 'FitKey pass not valid 6 PM – 8 PM (Mon–Fri)');
    });

    test('schedule round-trips through venue hours rows', () {
      final v = PartnerVenue(categories: ['gym']);
      final s = WeekSchedule()
        ..applyToDays(['mon', 'wed'], [Shift('06:00', '11:00'), Shift('17:00', '22:00')])
        ..ladies.add(DayWindow(days: ['mon', 'wed'], start: '07:00', end: '09:00'));
      s.writeTo(v);
      expect(v.hours.where((h) => h.kind == 'open'), hasLength(4));
      expect(v.hours.where((h) => h.ladiesOnly), hasLength(2));
      expect(v.openDays, ['mon', 'wed']);
      expect(v.opensAt, '06:00');
      expect(v.closesAt, '22:00');

      final back = WeekSchedule.fromVenue(PartnerVenue.fromJson({'hours': [for (final h in v.hours) h.toJson()]}));
      expect(back.open['mon'], [Shift('06:00', '11:00'), Shift('17:00', '22:00')]);
      expect(back.sameEveryDay, isTrue);
      expect(back.ladies.single.days, ['mon', 'wed']);
    });

    test('legacy venues without hours rows use opensAt / closesAt / openDays', () {
      final s = WeekSchedule.fromVenue(PartnerVenue(opensAt: '05:30', closesAt: '23:00', openDays: ['sat', 'sun']));
      expect(s.openDays, ['sat', 'sun']);
      expect(s.open['sat'], [Shift('05:30', '23:00')]);
    });
  });

  group('equipment quick-add is filtered by category', () {
    test('a gym never suggests courts or lanes', () {
      final gym = equipmentSuggestions(['gym'], []);
      expect(gym, contains('Treadmills'));
      expect(gym, isNot(contains('Badminton courts')));
      expect(gym, isNot(contains('Swimming lanes')));
    });

    test('sports club suggestions follow the selected sports', () {
      final s = equipmentSuggestions(['sports_club'], ['badminton']);
      expect(s, contains('Badminton courts'));
      expect(s, isNot(contains('Tennis courts')));
      expect(equipmentSuggestions(['swimming_pool'], []), contains('Swimming lanes'));
    });
  });

  group('payout previews (same maths as utils/commission.js)', () {
    test('FitKey pass per check-in', () {
      expect(passPreviewLine(150000, 1), '₹50 per check-in in Year 1');
      expect(passPreviewLine(150000, 2), contains('in Year 2'));
      expect(passPreviewLine(150000, 3), contains('Year 3 onwards'));
    });

    test('direct sale breakdown deducts GST 5/105 and the year commission', () {
      final b = directSaleBreakdown(105000); // ₹1,050
      expect(b.gst, 5000);
      expect(b.commission, 0);
      expect(b.net, 100000);
      final y3 = directSaleBreakdown(105000, year: 3);
      expect(y3.commission, 5250);
      expect(directSaleLine(105000), startsWith('You get ₹1,000'));
    });

    test('rupee parsing', () {
      expect(rupeesToPaise('1,499'), 149900);
      expect(rupeesToPaise('99.5'), 9950);
      expect(rupeesToPaise(''), isNull);
      expect(rupeesToPaise('abc'), isNull);
      expect(paiseToRupeesText(149900), '1499');
      expect(courtsLine(3, 'badminton', 60), '3 badminton courts × 1 hr');
    });
  });

  group('photo quality', () {
    Uint8List png(img.Image i) => Uint8List.fromList(img.encodePng(i));

    img.Image checkerboard(int w, int h, {int cell = 8}) {
      final i = img.Image(width: w, height: h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final on = ((x ~/ cell) + (y ~/ cell)).isEven;
          i.setPixelRgb(x, y, on ? 240 : 20, on ? 240 : 20, on ? 240 : 20);
        }
      }
      return i;
    }

    test('sharp photo of the right size passes', () {
      final r = checkPhoto(png(checkerboard(1000, 750)));
      expect(r.ok, isTrue, reason: r.message);
      expect(r.sharpness, greaterThan(blurThreshold));
    });

    test('too small is rejected', () {
      final r = checkPhoto(png(checkerboard(640, 480)));
      expect(r.ok, isFalse);
      expect(r.message, contains('too small'));
    });

    test('portrait 600 × 800 is fine', () {
      expect(checkPhoto(png(checkerboard(600, 800))).ok, isTrue);
    });

    test('blurry photo is rejected', () {
      final blurred = img.gaussianBlur(checkerboard(1000, 750, cell: 40), radius: 24);
      final r = checkPhoto(png(blurred));
      expect(r.ok, isFalse);
      expect(r.message, contains('blurry'));
    });

    test('garbage bytes are rejected politely', () {
      expect(checkPhoto(Uint8List.fromList([1, 2, 3])).ok, isFalse);
    });
  });
}
