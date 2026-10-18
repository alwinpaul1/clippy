import 'package:clippy/core/search/clip_search.dart';
import 'package:clippy/core/signals/clip_signals.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 10, 18, 12);

SearchDoc doc(String text, {String device = 'MacBook Pro', Duration ago = Duration.zero, bool image = false}) =>
    SearchDoc(
      text: text,
      device: device,
      isImage: image,
      signals: image ? const [] : detectSignals(text),
      timestamp: now.subtract(ago),
    );

double? s(SearchDoc d, String q) => scoreDoc(d, q, now: now);

void main() {
  test('empty query matches everything', () {
    expect(s(doc('anything'), '  '), 0);
  });

  test('every word must match', () {
    expect(s(doc('Meet at the Hauptbahnhof entrance'), 'hauptbahnhof entrance'), isNotNull);
    expect(s(doc('Meet at the Hauptbahnhof entrance'), 'hauptbahnhof exit'), isNull);
  });

  test('whole word > word start > fragment', () {
    final whole = s(doc('the track is here'), 'track')!;
    final prefix = s(doc('the tracking is here'), 'track')!;
    final frag = s(doc('the soundtrack is here'), 'track')!;
    expect(whole, greaterThan(prefix));
    expect(prefix, greaterThan(frag));
  });

  test('one typo in a long word still finds it; short words need to be exact', () {
    expect(s(doc('Meet at the Hauptbahnhof'), 'hauptbanhof'), isNotNull);
    expect(s(doc('my car is red'), 'cat'), isNull);
  });

  test('a strong old match beats a weak new one', () {
    final strongOld = s(doc('invoice for October', ago: const Duration(days: 6)), 'invoice')!;
    final weakNew = s(doc('reinvoiced later'), 'invoice')!;
    expect(strongOld, greaterThan(weakNew));
  });

  test('recency breaks a tie', () {
    expect(s(doc('invoice'), 'invoice')!,
        greaterThan(s(doc('invoice', ago: const Duration(days: 2)), 'invoice')!));
  });

  test('the phrase in order gets a bonus', () {
    expect(s(doc('meet at track 7 today'), 'track 7')!,
        greaterThan(s(doc('7 people on the track'), 'track 7')!));
  });

  test('signal keywords match the KIND of clip', () {
    expect(s(doc('Your verification code is 482913'), 'otp'), isNotNull);
    expect(s(doc('482913'), 'code'), isNotNull);
    expect(s(doc('4242 4242 4242 4242'), 'card'), isNotNull);
    expect(s(doc('DE89 3704 0044 0532 0130 00'), 'iban'), isNotNull);
    expect(s(doc('call +49 151 23456789'), 'phone'), isNotNull);
    expect(s(doc('https://github.com/x'), 'link'), isNotNull);
    expect(s(doc('hello there'), 'otp'), isNull);
  });

  test('a keyword combines with words: "link github"', () {
    expect(s(doc('https://github.com/alwinpaul1/clippy'), 'link github'), isNotNull);
    expect(s(doc('https://gitlab.com/x'), 'link github'), isNull);
  });

  test('device name matches', () {
    expect(s(doc('hello', device: 'SM-S918B'), 'sm-s918b'), isNotNull);
  });

  test('images match image words and their device, never text', () {
    expect(s(doc('', image: true), 'screenshot'), isNotNull);
    expect(s(doc('', image: true, device: 'Pixel 9'), 'pixel'), isNotNull);
    expect(s(doc('', image: true), 'hello'), isNull);
  });
}
