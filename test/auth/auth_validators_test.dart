import 'package:flutter_test/flutter_test.dart';
import 'package:morit/auth/moring_auth.dart';

void main() {
  group('email', () {
    test('accepts a normal address and the 320 character boundary', () {
      final maxLength = '${'a' * 64}@${'b' * 253}.c';
      expect(maxLength.length, 320);
      expect(MoringAuthValidators.email('  User@Example.com  '), isNull);
      expect(MoringAuthValidators.email(maxLength), isNull);
      expect(
        MoringAuthValidators.normalizeEmail('  User@Example.com  '),
        'user@example.com',
      );
    });

    test('rejects malformed and overlong addresses', () {
      final overlong = '${'a' * 64}@${'b' * 254}.c';
      expect(MoringAuthValidators.email('user@example'), isNotNull);
      expect(MoringAuthValidators.email('user @example.com'), isNotNull);
      expect(MoringAuthValidators.email(overlong), isNotNull);
    });
  });

  test('full name requires 2 to 100 Unicode code points', () {
    expect(MoringAuthValidators.fullName('가나'), isNull);
    expect(MoringAuthValidators.fullName('a' * 100), isNull);
    expect(MoringAuthValidators.fullName('가'), isNotNull);
    expect(MoringAuthValidators.fullName('a' * 101), isNotNull);
  });

  test('username allows only the documented characters and length', () {
    expect(MoringAuthValidators.username('가A_'), isNull);
    expect(MoringAuthValidators.username('한글.user_29'), isNull);
    expect(MoringAuthValidators.username('ab'), isNotNull);
    expect(MoringAuthValidators.username('a' * 31), isNotNull);
    expect(MoringAuthValidators.username('user-name'), isNotNull);
    expect(MoringAuthValidators.username('user name'), isNotNull);
    expect(MoringAuthValidators.username('.user'), isNotNull);
    expect(MoringAuthValidators.username('user.'), isNotNull);
    expect(MoringAuthValidators.username('user..name'), isNotNull);
  });

  test('password requires 8 to 128 Unicode code points', () {
    expect(MoringAuthValidators.password('12345678'), isNull);
    expect(MoringAuthValidators.password('🙂' * 8), isNull);
    expect(MoringAuthValidators.password('1234567'), isNotNull);
    expect(MoringAuthValidators.password('x' * 129), isNotNull);
  });

  test('OTP is exactly six ASCII digits', () {
    expect(MoringAuthValidators.otp('012345'), isNull);
    expect(MoringAuthValidators.otp('12345'), isNotNull);
    expect(MoringAuthValidators.otp('1234567'), isNotNull);
    expect(MoringAuthValidators.otp('12a456'), isNotNull);
  });

  group('birth date', () {
    final today = DateTime(2026, 7, 23, 23, 59);

    test('accepts real dates through today', () {
      expect(MoringAuthValidators.birthDate('2024-02-29', now: today), isNull);
      expect(MoringAuthValidators.birthDate('2026-07-23', now: today), isNull);
    });

    test('rejects normalized invalid dates and future dates', () {
      expect(
        MoringAuthValidators.birthDate('2025-02-29', now: today),
        isNotNull,
      );
      expect(
        MoringAuthValidators.birthDate('2026-13-01', now: today),
        isNotNull,
      );
      expect(
        MoringAuthValidators.birthDate('0000-01-01', now: today),
        isNotNull,
      );
      expect(
        MoringAuthValidators.birthDate('2026-07-24', now: today),
        isNotNull,
      );
    });
  });
}
