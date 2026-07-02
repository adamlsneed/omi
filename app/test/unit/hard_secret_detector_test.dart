import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/hard_secret_detector.dart';

void main() {
  group('HardSecretDetector', () {
    test('detects credential-shaped secrets', () {
      expect(HardSecretDetector.contains('api key sk-1234567890abcdefghijklmnop'), isTrue);
      expect(HardSecretDetector.contains('password = correct-horse-battery-staple'), isTrue);
      // HTTP header form: whitespace separator after "bearer" (no ':' or '=').
      expect(HardSecretDetector.contains('Authorization: bearer abcdefghijklmnopqrstuvwxyz123456'), isTrue);
      expect(HardSecretDetector.contains('bearer: abcdefghijklmnopqrstuvwxyz123456'), isTrue);
      expect(HardSecretDetector.contains('-----BEGIN PRIVATE KEY-----'), isTrue);
    });

    test('bearer needs a long opaque value, not prose', () {
      expect(HardSecretDetector.contains('the bearer of this message is a friend'), isFalse);
      expect(HardSecretDetector.contains('bearer bonds are a thing'), isFalse);
    });

    test('drops underscore-prefixed Stripe-style keys (parity with desktop)', () {
      // Stripe production keys use sk_ (underscore) separators. The mobile detector
      // must catch these, matching the Swift desktop detector's sk[-_] pattern,
      // so they are dropped before forwarding transcripts. Uses fake test values.
      expect(HardSecretDetector.contains('found sk_NOT_A_REAL_KEY_test1234'), isTrue);
      expect(HardSecretDetector.contains('key sk_DEMO_KEY_FAKE_VALUE1234'), isTrue);
      // Hyphen form must still be caught (regression guard).
      expect(HardSecretDetector.contains('token sk-FAKE_KEY_TEST_VALUE1234'), isTrue);
    });

    test('does not classify email PII as a hard secret', () {
      expect(HardSecretDetector.contains('Reach me at user@example.com.'), isFalse);
      expect(HardSecretDetector.categories('Reach me at user@example.com.'), isEmpty);
    });

    test('returns stable sorted categories', () {
      // Bare token= is caught (desktop parity).
      final categories = HardSecretDetector.categories(
        'token=abcdefghijklmnopqrstuvwxyz123456 and password=superSecret123',
      );

      expect(categories, ['password', 'token']);
    });
  });
}
