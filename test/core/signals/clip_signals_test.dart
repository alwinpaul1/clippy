import 'package:clippy/core/signals/clip_signals.dart';
import 'package:flutter_test/flutter_test.dart';

List<SignalKind> kinds(String t) => detectSignals(t).map((s) => s.kind).toList();
ClipSignal? first(String t, SignalKind k) {
  for (final s in detectSignals(t)) {
    if (s.kind == k) return s;
  }
  return null;
}

void main() {
  group('checksums', () {
    test('Luhn', () {
      expect(luhnValid('4242424242424242'), isTrue);
      expect(luhnValid('4242424242424241'), isFalse);
    });
    test('IBAN mod 97', () {
      expect(isValidIban('DE89 3704 0044 0532 0130 00'), isTrue);
      expect(isValidIban('GB82WEST12345698765432'), isTrue);
      expect(isValidIban('DE89 3704 0044 0532 0130 01'), isFalse);
    });
  });

  group('sensitive', () {
    test('a card number with spaces or dashes is a card', () {
      expect(kinds('4242 4242 4242 4242'), [SignalKind.card]);
      expect(kinds('Card: 5555-5555-5555-4444 exp 12/29'), contains(SignalKind.card));
    });
    test('a 16-digit order number that fails Luhn is NOT a card', () {
      expect(kinds('Order 4242424242424241'), isNot(contains(SignalKind.card)));
    });
    test('a repeated digit run is not a card even though it passes Luhn', () {
      expect(kinds('0000000000000000'), isNot(contains(SignalKind.card)));
    });
    test('an IBAN, grouped or not, any case', () {
      expect(kinds('DE89 3704 0044 0532 0130 00'), [SignalKind.iban]);
      expect(kinds('iban: de89370400440532013000'), contains(SignalKind.iban));
    });
    test('an invalid IBAN is ignored', () {
      expect(kinds('DE89 3704 0044 0532 0130 01'), isNot(contains(SignalKind.iban)));
    });
    test('masking keeps only enough to tell two apart', () {
      expect(maskSensitive(first('4242 4242 4242 4242', SignalKind.card)!), '•••• 4242');
      expect(maskSensitive(first('DE89 3704 0044 0532 0130 00', SignalKind.iban)!),
          'DE89 •••• 3000');
    });
    test('hasSensitive', () {
      expect(hasSensitive(detectSignals('4242 4242 4242 4242')), isTrue);
      expect(hasSensitive(detectSignals('hello')), isFalse);
    });
  });

  group('OTP', () {
    test('a clip that IS a 6-8 digit code', () {
      expect(kinds('482913'), [SignalKind.otp]);
      expect(kinds(' 482 913 '), [SignalKind.otp]);
      expect(otpDigits(first('482-913', SignalKind.otp)!), '482913');
    });
    test('a bare 4-digit clip is not assumed to be a code', () {
      expect(kinds('2026'), isEmpty);
    });
    test('a message naming a code', () {
      expect(otpDigits(first('Your verification code is 482913.', SignalKind.otp)!), '482913');
      expect(otpDigits(first('Ihr Bestätigungscode: 4829', SignalKind.otp)!), '4829');
      expect(otpDigits(first('G-582194 is your Google verification code.', SignalKind.otp)!),
          '582194');
    });
    test('the code after the keyword wins over an earlier number', () {
      final s = first('Call 0151 2345678 if this was not you. Your code is 4829', SignalKind.otp);
      expect(otpDigits(s!), '4829');
    });
    test('no keyword, no code inside prose', () {
      expect(kinds('We need 4829 more units by Friday'), isNot(contains(SignalKind.otp)));
    });
  });

  group('contact and places', () {
    test('phone numbers', () {
      expect(first('Call me: +49 151 23456789', SignalKind.phone)?.value, '+49 151 23456789');
      expect(kinds('030 1234567'), contains(SignalKind.phone));
    });
    test('email', () {
      expect(first('mail alwin@example.com today', SignalKind.email)?.value, 'alwin@example.com');
    });
    test('url, trailing punctuation dropped', () {
      expect(first('see https://clippy.alwinpaul.me/download).', SignalKind.url)?.value,
          'https://clippy.alwinpaul.me/download');
    });
    test('a phone-looking run inside a URL stays part of the URL', () {
      expect(kinds('https://example.com/orders/015123456789'), [SignalKind.url]);
    });
    test('addresses, English and German', () {
      expect(kinds('221B Baker Street, London'), contains(SignalKind.address));
      expect(first('Meet at Hauptstraße 5, 10117 Berlin', SignalKind.address)?.value,
          'Hauptstraße 5, 10117 Berlin');
    });
    test('dates and times', () {
      expect(kinds('due 31.10.2026'), contains(SignalKind.date));
      expect(kinds('track 7 at 18:40'), contains(SignalKind.date));
      expect(kinds('2026-10-18'), [SignalKind.date]);
    });
  });

  test('plain prose has no signals', () {
    expect(kinds('The quick brown fox jumps over the lazy dog.'), isEmpty);
  });

  test('a huge clip is not scanned', () {
    expect(detectSignals('4242 4242 4242 4242 ${'x' * 5000}'), isEmpty);
  });
}
