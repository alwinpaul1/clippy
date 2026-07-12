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
    ClipQueue.resetForTests(); // no strike/cooldown bleed between tests
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

    expect(attempts, 5,
        reason: 'the batch is attempted once — that is how a global fault is '
            'told apart from a bad clip — but ONCE, not re-drained in a loop');
    expect(onDisk(), hasLength(5),
        reason: 'every clip must still be on disk, the only crash-proof copy');
    expect(tmp.listSync().where((f) => f.path.endsWith('.dead')), isEmpty,
        reason: 'and nothing may be blamed/quarantined: nothing proved the '
            'engine even works');
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

  test('a failure AFTER a success is set aside — it STAYS ON DISK for a later '
      'retry, and the rest of the batch still syncs', () async {
    put('001.txt', 'good');
    put('002.txt', 'bad');
    put('003.txt', 'also-good');
    final delivered = <String>[];

    await drainer((item) async {
      if (item.text == 'bad') throw StateError('this one clip is broken');
      delivered.add(item.text!);
    }).run();

    expect(delivered, containsAll(['good', 'also-good']),
        reason: 'the engine demonstrably works — one bad clip must not hold '
            'the whole queue hostage');
    expect(onDisk(), contains('002.txt'),
        reason: 'ONE strike is not proof of poison: the clip must survive on '
            'disk for a later, time-separated retry — not be quarantined three '
            'times over inside this single run');
  });

  /// The exact shape that used to destroy the backlog: the engine works for the
  /// first clip and then dies (disk full — which a 200MB queue itself causes —
  /// or an OOM on a big image). Every later clip fails, but NOT because it is
  /// bad.
  test('an engine that dies MID-BATCH does not quarantine the whole backlog',
      () async {
    for (var i = 1; i <= 8; i++) {
      put('00$i.txt', 'clip-$i');
    }
    var done = 0;

    await drainer((item) async {
      if (done >= 1) throw StateError('disk full');
      done++;
    }).run();

    expect(tmp.listSync().where((f) => f.path.endsWith('.dead')), isEmpty,
        reason: 'ONE strike each — a two-second hiccup must never quarantine '
            'seven clips in a single run');
    expect(onDisk().where((n) => n.endsWith('.txt')), hasLength(7),
        reason: 'the undelivered clips must all be back on disk');
    expect(ClipQueue.inCooldown, isTrue,
        reason: 'and the drainer must NOT report success on a run that '
            'delivered 1 of 8');
  });

  test('a clip that fails every time is quarantined only after SEPARATE runs, '
      'and is parked rather than destroyed', () async {
    Future<void> attempt() async {
      put('001.txt', 'good'); // a fresh good clip each run proves the engine
      ClipQueue.noteDrainSuccess(); // the cooldown expires between runs
      await drainer((item) async {
        if (item.text == 'poison') throw StateError('unprocessable');
      }).run();
    }

    put('002.txt', 'poison');
    await attempt();
    expect(onDisk(), contains('002.txt'), reason: 'strike 1 — still queued');
    await attempt();
    expect(onDisk(), contains('002.txt'), reason: 'strike 2 — still queued');
    await attempt();

    expect(File('${tmp.path}/002.txt.dead').existsSync(), isTrue,
        reason: 'only now, after three SEPARATE runs, is it poison — and it is '
            'parked, not destroyed (drain() already deleted the original)');
    expect(onDisk().where((n) => n.endsWith('.txt')), isEmpty,
        reason: 'and it no longer blocks the queue');
  });

  test('a bad clip ALONE in the queue still stops blocking it eventually — but '
      'only after it has been failing long enough to rule out an outage',
      () async {
    put('001.txt', 'poison');
    Future<void> attempt() async {
      ClipQueue.noteDrainSuccess();
      await drainer((item) async => throw StateError('unprocessable')).run();
    }

    // Nothing else can ever succeed to prove the engine works, so a naive
    // "only blame a clip when something else worked" rule jams the queue for
    // good. Early on, judgement is withheld: a real outage looks the same.
    await attempt();
    await attempt();
    await attempt();
    expect(onDisk(), ['001.txt'],
        reason: 'a 30-second global fault must not park anything');

    // Once it has been failing far longer than any transient fault, give up on
    // it — parked, not destroyed — so the queue can move again.
    ClipQueue.poisonMinAge = Duration.zero;
    await attempt();

    expect(File("${tmp.path}/001.txt.dead").existsSync(), isTrue);
    expect(onDisk().where((n) => n.endsWith('.txt')), isEmpty,
        reason: 'the queue is unblocked');
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
    var uploads = 0;
    final d = drainer((item) async {
      uploads++; // COUNT it: "the disk ends empty" is true either way
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });

    await Future.wait([d.run(), d.run()]); // watcher + reconnect at once

    expect(uploads, 1,
        reason: 'both passes can list the file before either deletes it — the '
            'clip would sync twice, and the older one would land last as the '
            "room's newest");
    expect(onDisk(), isEmpty);
  });
}
