import 'package:clippy/core/search/clip_search.dart';
import 'package:clippy/core/vision/image_index.dart';
import 'package:flutter_test/flutter_test.dart';

SearchDoc shot(String text, {List<String> labels = const []}) {
  final insight = ImageInsight(text: text, labels: labels);
  return SearchDoc(
    text: '',
    device: 'Pixel 9',
    isImage: true,
    signals: insight.signals,
    timestamp: DateTime(2026, 10, 18),
    imageText: insight.text,
    imageLabels: insight.labels,
  );
}

double? s(SearchDoc d, String q) => scoreDoc(d, q, now: DateTime(2026, 10, 18));

void main() {
  test('a screenshot is found by the text in it', () {
    final d = shot('Boarding pass\nGate B42 · Seat 17C\nLufthansa LH 2034');
    expect(s(d, 'gate b42'), isNotNull);
    expect(s(d, 'lufthansa'), isNotNull);
    expect(s(d, 'lufthnsa'), isNotNull, reason: 'one-letter typo');
    expect(s(d, 'ryanair'), isNull);
  });

  test('a photo is found by what it shows', () {
    final d = shot('', labels: const ['dog', 'grass', 'credit card']);
    expect(s(d, 'dog'), isNotNull);
    expect(s(d, 'dogs'), isNotNull, reason: 'plural of a label');
    expect(s(d, 'card'), isNotNull, reason: 'one word of a two-word label');
    expect(s(d, 'cat'), isNull);
  });

  test('signal keywords reach into image text', () {
    expect(s(shot('Your verification code is 482913'), 'code'), isNotNull);
    expect(s(shot('https://github.com/alwinpaul1/clippy'), 'link'), isNotNull);
  });

  test('every query word must match, across text and labels', () {
    final d = shot('Invoice 2026-114', labels: const ['document']);
    expect(s(d, 'invoice document'), isNotNull);
    expect(s(d, 'invoice dog'), isNull);
  });

  test('an image not yet read still matches image words', () {
    expect(s(shot(''), 'screenshot'), isNotNull);
    expect(s(shot(''), 'gate'), isNull);
  });

  group('imageTextSnippet', () {
    test('picks the line with the most query words', () {
      expect(
        imageTextSnippet('Boarding pass\nGate B42 · Seat 17C', 'seat gate'),
        'Gate B42 · Seat 17C',
      );
    });

    test('cuts a long line around the hit', () {
      final long = '${'x' * 100} hauptbahnhof ${'y' * 100}';
      final out = imageTextSnippet(long, 'hauptbahnhof', max: 40)!;
      expect(out, contains('hauptbahnhof'));
      expect(out.startsWith('…'), isTrue);
      expect(out.endsWith('…'), isTrue);
      expect(out.length, lessThanOrEqualTo(42));
    });

    test('null when no line holds a query word', () {
      expect(imageTextSnippet('hello', 'dog'), isNull);
      expect(imageTextSnippet('', 'dog'), isNull);
    });
  });
}
