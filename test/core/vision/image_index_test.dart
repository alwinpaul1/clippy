import 'dart:typed_data';

import 'package:clippy/core/signals/clip_signals.dart';
import 'package:clippy/core/vision/image_index.dart';
import 'package:flutter_test/flutter_test.dart';

IndexImage img(String hash, [int byte = 1]) =>
    (hash: hash, bytes: Uint8List.fromList([byte]));

void main() {
  test('analyses each image once, newest first, and forgets removed ones',
      () async {
    final seen = <int>[];
    var changes = 0;
    final index = ImageIndex(
      analyze: (b) async {
        seen.add(b.first);
        return ImageInsight(text: 'text ${b.first}', labels: const ['dog']);
      },
      onChange: () => changes++,
    );
    index.sync([img('b', 2), img('a', 1)]);
    await index.idle();
    expect(seen, [2, 1]);
    expect(index.of('a')!.text, 'text 1');
    expect(changes, greaterThanOrEqualTo(2));

    index.sync([img('b', 2), img('a', 1)]); // nothing new
    await index.idle();
    expect(seen, [2, 1]);

    index.sync([img('a', 1)]); // b left the history
    expect(index.of('b'), isNull);
    expect(index.pending, 0);
  });

  test('a failed image is retried on a later sync, then left alone',
      () async {
    var calls = 0;
    final index = ImageIndex(analyze: (_) async {
      calls++;
      return null;
    });
    for (var i = 0; i < 4; i++) {
      index.sync([img('x')]);
      await index.idle();
    }
    expect(calls, ImageIndex.maxAttempts);
    expect(index.of('x'), isNull);
  });

  test('a hung analysis times out instead of blocking the queue', () async {
    final index = ImageIndex(
      timeout: const Duration(milliseconds: 20),
      analyze: (b) => b.first == 1
          ? Future<ImageInsight?>.delayed(const Duration(seconds: 5))
          : Future.value(ImageInsight(text: 'ok', labels: const [])),
    );
    index.sync([img('slow', 1), img('fast', 2)]);
    await index.idle();
    expect(index.of('fast')!.text, 'ok');
    expect(index.of('slow'), isNull);
  });

  test('an unsupported platform stops the queue for good', () async {
    var calls = 0;
    final index = ImageIndex(analyze: (_) async {
      calls++;
      throw UnsupportedError('none');
    });
    index.sync([img('a'), img('b')]);
    await index.idle();
    index.sync([img('c')]);
    await index.idle();
    expect(calls, 1);
    expect(index.supported, isFalse);
  });

  test('text in an image carries signals, so "code" can find it', () {
    final i = ImageInsight(
      text: 'Your verification code is 482913',
      labels: const [],
    );
    expect(i.signals.map((s) => s.kind), contains(SignalKind.otp));
    expect(i.hasText, isTrue);
  });
}
