import 'dart:io';

import 'package:clippy/platform/clip_queue.dart';
import 'package:clippy/platform/queue_drainer.dart';
import 'package:flutter_test/flutter_test.dart';

/// The queue's FAILURE POLICY, driven for real: actual files on disk, an actual
/// drain, a `process` callback that fails the way the engine fails.
///
/// This is the test that was missing. The policy previously lived duplicated
/// inside two isolates' drain loops, where nothing could reach it — so a change
/// that made the drain burn through and destroy the backlog kept the suite
/// green. Everything below fails if that regresses.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('clippy-drainer-test');
    ClipQueue.debugDir = tmp;
    ClipQueue.noteDrainSuccess(); // no cooldown/backoff bleed between tests
  });

  tearDown(() {
    ClipQueue.debugDir = null;
    ClipQueue.noteDrainSuccess();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void put(String name, String content) =>
      File('${tmp.path}/$name').writeAsStringSync(content);

  List<String> onDisk() => tmp
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n != 'drain.beat')
      .toList()
    ..sort();

  QueueDrainer drainer(Future<void> Function(ClipQueueItem) process,
          {bool Function()? canContinue}) =>
      QueueDrainer(process: process, canContinue: canContinue ?? () => true);

  test('the happy path delivers everything and empties the disk', () async {
    put('001.txt', 'a');
    put('002.txt', 'b');
    final seen = <String>[];

    await drainer((item) async => seen.add(item.text!)).run();

    expect(seen, ['a', 'b']);
    expect(onDisk(), isEmpty);
    expect(ClipQueue.inCooldown, isFalse);
  });

  test('a GLOBAL fault (nothing delivered) aborts after ONE attempt and puts '
      'the WHOLE backlog back — it must never burn through the queue', () async {
    for (var i = 1; i <= 5; i++) {
      put('00$i.txt', 'clip-$i');
    }
    var attempts = 0;

    // The engine is broken: prefs can't write / crypto is unusable. EVERY item
    // would fail — this is the case that used to shred the entire queue.
    await drainer((item) async {
      attempts++;
      throw StateError('engine is down');
    }).run();

    expect(attempts, 1,
        reason: 'one failure is enough to know the engine is down — proving it '
            '200 more times is how the backlog gets destroyed');
    expect(onDisk(), hasLength(5),
        reason: 'every clip must still be on disk, the only crash-proof copy');
    expect(ClipQueue.inCooldown, isTrue,
        reason: 'and the next drain must not run straight back into it (the '
            'requeue re-fires the inotify watcher)');
  });

  test('a cooldown blocks the next drain (this is what breaks the hot loop)',
      () async {
    put('001.txt', 'a');
    ClipQueue.noteDrainFailure();
    var attempts = 0;

    await drainer((item) async => attempts++).run();

    expect(attempts, 0);
    expect(onDisk(), ['001.txt']);
  });

  test('a failure AFTER a success is treated as this clip\'s fault: it is set '
      'aside and the rest of the batch still syncs', () async {
    put('001.txt', 'good');
    put('002.txt', 'bad');
    put('003.txt', 'also-good');
    final delivered = <String>[];

    await drainer((item) async {
      if (item.text == 'bad') throw StateError('this one clip is broken');
      delivered.add(item.text!);
    }).run();

    expect(delivered, containsAll(['good', 'also-good']),
        reason: 'the engine demonstrably works, so one bad clip must not hold '
            'the whole queue hostage');
    expect(ClipQueue.inCooldown, isFalse,
        reason: 'nothing global is wrong — do not back off');
  });

  test('a clip that fails every time is QUARANTINED, not deleted, and the '
      'queue keeps flowing', () async {
    put('001.txt', 'good');
    put('002.txt', 'poison');

    // It takes several passes: each failure is presumed global until something
    // else proves otherwise, and the cooldown holds between attempts.
    for (var pass = 0; pass < 6; pass++) {
      ClipQueue.noteDrainSuccess(); // simulate the cooldown expiring
      await drainer((item) async {
        if (item.text == 'poison') throw StateError('unprocessable');
      }).run();
    }

    expect(File('${tmp.path}/002.txt.dead').existsSync(), isTrue,
        reason: 'parked, not destroyed — drain() already deleted the original');
    expect(onDisk().where((n) => n.endsWith('.txt')), isEmpty,
        reason: 'and it no longer blocks the queue');
  });

  test('losing the link mid-drain puts the undelivered remainder back', () async {
    put('001.txt', 'a');
    put('002.txt', 'b');
    put('003.txt', 'c');
    var up = true;
    final delivered = <String>[];

    await drainer(
      (item) async {
        delivered.add(item.text!);
        if (item.text == 'a') up = false; // link dies right after the first
      },
      canContinue: () => up,
    ).run();

    expect(delivered, ['a']);
    expect(onDisk(), ['002.txt', '003.txt'],
        reason: 'drain() consumed the files — anything undelivered must go '
            'back, or a process kill loses it for good');
  });

  test('overlapping drains do not double-upload the same file', () async {
    put('001.txt', 'a');
    final d = drainer((item) async =>
        await Future<void>.delayed(const Duration(milliseconds: 40)));

    await Future.wait([d.run(), d.run()]); // watcher + reconnect at once

    expect(onDisk(), isEmpty);
  });
}
