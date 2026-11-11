import 'package:fitkey_partner/widgets/listing/documents_bank_step.dart';
import 'package:fitkey_partner/data/types_api.dart' show normalizeIndianMobile;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IFSC', () {
    test('accepts valid codes (any case, trimmed)', () {
      expect(ListingValidators.ifsc('HDFC0001234'), isNull);
      expect(ListingValidators.ifsc('sbin0005943'), isNull);
      expect(ListingValidators.ifsc(' ICIC0ABC123 '), isNull);
    });
    test('rejects bad codes', () {
      expect(ListingValidators.ifsc(''), isNotNull);
      expect(ListingValidators.ifsc(null), isNotNull);
      expect(ListingValidators.ifsc('HDFC1001234'), isNotNull, reason: '5th char must be 0');
      expect(ListingValidators.ifsc('HDF00001234'), isNotNull, reason: 'first 4 must be letters');
      expect(ListingValidators.ifsc('HDFC000123'), isNotNull, reason: 'too short');
      expect(ListingValidators.ifsc('HDFC00012345'), isNotNull, reason: 'too long');
      expect(ListingValidators.ifsc('HDFC0-01234'), isNotNull);
    });
    test('upper-case formatter', () {
      const f = UpperCaseFormatter();
      final out = f.formatEditUpdate(TextEditingValue.empty, const TextEditingValue(text: 'hdfc0abc'));
      expect(out.text, 'HDFC0ABC');
    });
  });

  group('Aadhaar last 4', () {
    test('accepts exactly 4 digits', () {
      expect(ListingValidators.aadhaarLast4('1234'), isNull);
      expect(ListingValidators.aadhaarLast4(' 0007 '), isNull);
    });
    test('refuses full numbers and junk', () {
      expect(ListingValidators.aadhaarLast4(''), isNotNull);
      expect(ListingValidators.aadhaarLast4('123'), isNotNull);
      expect(ListingValidators.aadhaarLast4('12a4'), isNotNull);
      expect(ListingValidators.aadhaarLast4('123456789012'), contains('never your full Aadhaar'));
      expect(ListingValidators.aadhaarLast4('1234 5678 9012'), contains('never your full Aadhaar'));
    });
    test('masking', () => expect(ListingValidators.maskAadhaar('1234'), 'XXXX-XXXX-1234'));
  });

  group('Account number', () {
    test('9–18 digits', () {
      expect(ListingValidators.accountNumber('123456789'), isNull);
      expect(ListingValidators.accountNumber('123456789012345678'), isNull);
      expect(ListingValidators.accountNumber('12345678'), isNotNull);
      expect(ListingValidators.accountNumber('1234567890123456789'), isNotNull);
      expect(ListingValidators.accountNumber('12345678a'), isNotNull);
      expect(ListingValidators.accountNumber(''), isNotNull);
    });
    test('confirm must match', () {
      expect(ListingValidators.confirmAccountNumber('123456789012', '123456789012'), isNull);
      expect(ListingValidators.confirmAccountNumber('123456789012', '123456789013'), isNotNull);
      expect(ListingValidators.confirmAccountNumber('123456789012', ''), isNotNull);
      expect(ListingValidators.confirmAccountNumber('1234 5678 9012', '123456789012'), isNull);
    });
  });

  test('names', () {
    expect(ListingValidators.nameOnId('Ravi Kumar'), isNull);
    expect(ListingValidators.nameOnId(' '), isNotNull);
    expect(ListingValidators.holderName('A'), isNotNull);
  });

  test('partner mobile normalisation', () {
    expect(normalizeIndianMobile('9876543210'), '9876543210');
    expect(normalizeIndianMobile('+91 98765 43210'), '9876543210');
    expect(normalizeIndianMobile('09876543210'), '9876543210');
    expect(normalizeIndianMobile('1234567890'), isNull);
    expect(normalizeIndianMobile('98765'), isNull);
  });
}
