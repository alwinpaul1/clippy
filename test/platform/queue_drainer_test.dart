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

  test('a cooldown blocks RETRYING a clip we already failed on (this is what '
      'breaks the hot loop)', () async {
    put('001.txt', 'bad');
    // Fail it once, which requeues it and sets the hold.
    await drainer((item) async => throw StateError('nope')).run();
    expect(ClipQueue.inCooldown, isTrue);
    var attempts = 0;

    await drainer((item) async => attempts++).run();

    expect(attempts, 0,
        reason: 'the requeue re-fires the inotify watcher — without the hold '
            'that is a spin');
    expect(onDisk(), ['001.txt']);
  });

  test('a cooldown NEVER blocks a clip we have not tried — the user\'s next '
      'copy must not wait behind a jam', () async {
    put('001.txt', 'bad');
    await drainer((item) async => throw StateError('nope')).run();
    expect(ClipQueue.inCooldown, isTrue);

    put('900.txt', 'the user just copied this');
    final synced = <String>[];

    await drainer((item) async {
      if (item.text == 'bad') throw StateError('nope');
      synced.add(item.name!);
    }).run();

    expect(synced, ['900.txt'],
        reason: 'a hold on a known-bad clip must never make a FRESH clip wait — '
            'that is up to four minutes of latency for something that has never '
            'failed once');
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

  test('a clip that fails every time is parked only after SEPARATE runs, and is '
      'parked rather than destroyed', () async {
    var seq = 100;
    Future<void> attempt() async {
      // A newer clip, drained AFTER the poison one — only a delivery that comes
      // after a failure is evidence against it (an engine that dies part-way
      // delivers first and throws after; that must convict nobody).
      put('${seq++}.txt', 'good');
      ClipQueue.expireCooldownForTests();
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

  test('a bad clip alone in the queue is never blamed on its own — but the '
      'moment ANY clip syncs, the engine is proven and it takes its strikes',
      () async {
    put('001.txt', 'poison');
    Future<void> attempt() async {
      ClipQueue.noteDrainSuccess(); // cooldowns expire
      await drainer((item) async {
        if (item.text == 'poison') throw StateError('unprocessable');
      }).run();
    }

    // Alone, it is indistinguishable from a broken engine: never parked.
    await attempt();
    await attempt();
    await attempt();
    expect(onDisk(), ['001.txt']);
    expect(tmp.listSync().where((f) => f.path.endsWith('.dead')), isEmpty,
        reason: 'nothing proved the engine works — blame nobody');

    // A new clip arrives. It syncs (so the engine IS working), which is what
    // finally makes the bad clip answerable.
    for (var run = 0; run < 3; run++) {
      put('00${run + 2}.txt', 'good');
      await attempt();
    }

    expect(File('${tmp.path}/001.txt.dead').existsSync(), isTrue,
        reason: 'three strikes from three separate engine-proven runs');
    expect(onDisk().where((n) => n.endsWith('.txt')), isEmpty,
        reason: 'and the good clips all synced');
  });

  /// The starvation case: a batch-FILLING set of clips that always fail. If
  /// failures were written straight back to disk, drain() would re-read the same
  /// 30 forever and the good clip behind them would never once be attempted —
  /// the device silently stops syncing, permanently.
  test('a jam of ANY size does not starve the good clips behind it (61 clips — '
      'past every internal batch and memory bound)', () async {
    for (var i = 1; i <= 61; i++) {
      put('${i.toString().padLeft(3, '0')}.txt', 'bad');
    }
    final synced = <String>[];

    for (var run = 0; run < 4; run++) {
      put('90$run.txt', 'good'); // a fresh copy, BEHIND the jam each time
      ClipQueue.noteDrainSuccess(); // cooldowns expire between runs
      await drainer((item) async {
        if (item.text == 'bad') throw StateError('unprocessable');
        synced.add(item.name!);
      }).run();
    }

    expect(synced, contains('900.txt'),
        reason: 'the good clip must get through on the FIRST run — a jammed '
            'head must never stop the whole device from syncing');
    // NOT destroyed: every one of the 61 is still there — most still queued,
    // and only those with genuine SAME-BATCH evidence against them parked.
    // A jam bigger than one batch is stepped over and retried rather than
    // convicted, because no good clip ever lands in its batch. That is
    // deliberate: convicting it would mean accepting run-global evidence, and a
    // transient fault that fails a batch then heals would destroy thirty
    // innocent clips (see the recovering-engine test). Stale files are cheap;
    // destroyed clips are not.
    final stillQueued =
        onDisk().where((n) => n.startsWith('0') && n.endsWith('.txt')).length;
    final parked = onDisk().where((n) => n.endsWith('.dead')).length;
    expect(stillQueued + parked, 61, reason: 'not one clip may be destroyed');
    // Conservation alone is vacuous — it holds even if the policy quarantined
    // all 61 (which enforceBound reaps a day later). Bound the convictions: only
    // a clip with genuine SAME-BATCH evidence may be parked, which here is the
    // handful sharing the final batch with a good clip.
    expect(parked, lessThan(5),
        reason: 'a jam must be stepped over, not convicted wholesale');
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

  /// The canonical shape, and the one that destroyed a clip: store.append()
  /// throws BECAUSE the socket died — and canContinue() reads that same socket,
  /// so it goes false on the very next iteration. A clip that threw is held in
  /// memory, and an early return must not walk away from it: drain() already
  /// deleted its file, so at that instant it exists NOWHERE else.
  /// The engine delivers one clip and then dies — a disk filling up: the first
  /// prefs write fits, the next does not. Repeated over runs, "something synced
  /// earlier in this run" would frame every clip behind the death and park them
  /// all. Only a delivery AFTER the failure is evidence against a clip.
  test('an engine that dies part-way through, run after run, never blames the '
      'clips behind the death', () async {
    for (var i = 1; i <= 8; i++) {
      put('00$i.txt', 'clip-$i');
    }

    for (var run = 0; run < 4; run++) {
      ClipQueue.noteDrainSuccess(); // cooldowns expire
      var alive = 1; // exactly one clip goes through, then the disk is full
      await drainer((item) async {
        if (alive-- <= 0) throw StateError('disk full');
      }).run();
    }

    expect(tmp.listSync().where((f) => f.path.endsWith('.dead')), isEmpty,
        reason: 'nothing was ever delivered AFTER these clips failed — the '
            'engine died, and a dying engine must never convict the backlog');
  });

  test('an unprocessable clip that cannot even be PARKED does not pin sync '
      'latency at four minutes', () async {
    put('001.txt', 'poison');
    Directory('${tmp.path}/001.txt.dead').createSync(); // the park will fail

    for (var run = 0; run < 6; run++) {
      put('90$run.txt', 'good'); // proves the engine, so 001 is answerable
      ClipQueue.expireCooldownForTests();
      await drainer((item) async {
        if (item.text == 'poison') throw StateError('unprocessable');
      }).run();
    }

    expect(ClipQueue.drainFailures, 0,
        reason: 'the engine is demonstrably healthy — a clip it cannot swallow '
            'must not escalate the backoff and make every good clip wait');
    expect(File('${tmp.path}/001.txt').existsSync(), isTrue,
        reason: 'and the clip is still queued, not destroyed');
  });

  /// The mirror of the dying-engine case, and just as destructive: a transient
  /// global fault (memory pressure while a 24MB batch is in flight) fails a
  /// whole batch, then HEALS — and the next batch's clip syncs fine. A
  /// run-global "something was delivered" rule convicts all 30 innocent clips.
  test('an engine that RECOVERS later in the run does not convict the clips '
      'that failed before it healed', () async {
    for (var i = 1; i <= 30; i++) {
      put('${i.toString().padLeft(3, '0')}.txt', 'batch-one');
    }

    for (var run = 0; run < 4; run++) {
      put('90$run.txt', 'copied-after'); // lands in the NEXT batch
      ClipQueue.expireCooldownForTests();
      var pressure = 30; // the first batch fails; then the pressure lifts
      await drainer((item) async {
        if (pressure-- > 0) throw StateError('out of memory');
      }).run();
    }

    expect(tmp.listSync().where((f) => f.path.endsWith('.dead')), isEmpty,
        reason: 'nothing synced AFTER them IN THEIR BATCH — a fault that heals '
            'in a later batch is evidence about the engine, not about them');
    expect(onDisk().where((n) => n.endsWith('.txt')), hasLength(30),
        reason: 'all thirty innocent clips must still be queued');
  });

  test('a clip whose file cannot be deleted is not delivered twice (and does '
      'not spin the drain forever)', () async {
    put('001.txt', 'undeletable');
    var uploads = 0;

    await drainer((item) async {
      uploads++;
      // Simulate drain()'s delete silently failing: the file is back.
      File('${tmp.path}/001.txt').writeAsStringSync('undeletable');
    }).run();

    expect(uploads, 1,
        reason: 'the run must not re-read and re-sync the same clip forever — '
            'every handled name is remembered, delivered or failed');
  });

  /// A clip too big for the batch byte-budget is ALWAYS returned alone in its
  /// batch, so same-batch evidence against it can never exist. Without the solo
  /// rule it could never be blamed, never parked — and would re-read its bulk
  /// from flash on every drain, forever.
  test('an OVERSIZED clip, always alone in its batch, is still parked', () async {
    ClipQueue.maxDrainBytes = 100; // tiny, so the big clip gets a batch to itself
    addTearDown(() => ClipQueue.maxDrainBytes = 24 << 20);
    put('001.txt', 'x' * 500); // over budget -> always solo

    for (var run = 0; run < 3; run++) {
      put('90$run.txt', 'good'); // syncs in a LATER batch — the engine works
      ClipQueue.expireCooldownForTests();
      await drainer((item) async {
        if (item.text!.length > 100) throw StateError('too big to encode');
      }).run();
    }

    expect(File('${tmp.path}/001.txt.dead').existsSync(), isTrue,
        reason: 'it is alone in its batch by construction — a delivery later in '
            'the RUN is the only evidence it can ever have, and a broken engine '
            'would have delivered nothing at all');
  });

  /// The backoff must key off "did the engine deliver anything", not "did we
  /// manage to convict someone". A jam we cannot convict is still a jam behind
  /// which perfectly good clips are syncing — escalating punishes THEM, and a
  /// run with failures never clears the backoff, so it would never heal.
  test('a jam we cannot convict does not escalate the backoff while good clips '
      'are syncing', () async {
    ClipQueue.maxDrainFiles = 3;
    addTearDown(() => ClipQueue.maxDrainFiles = 30);
    for (var i = 1; i <= 3; i++) {
      put('00$i.txt', 'bad'); // fills a whole batch: never same-batch evidence
    }

    for (var run = 0; run < 6; run++) {
      put('90$run.txt', 'good'); // delivers in a LATER batch, every run
      ClipQueue.expireCooldownForTests();
      await drainer((item) async {
        if (item.text == 'bad') throw StateError('unprocessable');
      }).run();
    }

    expect(ClipQueue.drainFailures, 0,
        reason: 'the engine delivered on every single run — pinning the cooldown '
            'at 4 minutes would make every good clip wait for a jam that is not '
            'even the engine\'s fault');
  });

  /// The regression that slipped past twenty tests: a DYING engine delivers
  /// first and throws after (the disk fills up mid-run). "Something was
  /// delivered" cannot see that — it reads as healthy, takes a flat 15s hold,
  /// and then re-reads and re-WRITES the entire backlog against a full disk
  /// every 20 seconds. Requeue writes are best-effort; hammering them during a
  /// disk-full fault is how a rare loss stops being rare.
  test('a DYING engine escalates the backoff — evidence must come AFTER the '
      'failure, for the engine exactly as for the clips', () async {
    for (var i = 1; i <= 8; i++) {
      put('00$i.txt', 'clip-$i');
    }

    for (var run = 0; run < 3; run++) {
      ClipQueue.expireCooldownForTests();
      var slack = 1; // the first write fits; the disk is full after that
      await drainer((item) async {
        if (slack-- <= 0) throw StateError('disk full');
      }).run();
    }

    expect(ClipQueue.drainFailures, greaterThan(1),
        reason: 'the LAST thing that happened was a failure — the engine is '
            'dying, and must be backed off from, not politely held for 15s');
  });

  /// The bypass must not become a licence to re-read the whole known-bad
  /// backlog. Requeue writes are best-effort against a possibly-full disk;
  /// dragging 200 failures back through it every time the user copies something
  /// is worse than the hammering the backoff exists to stop.
  test('a cooldown run touches ONLY untried clips, never the known-bad backlog',
      () async {
    for (var i = 1; i <= 5; i++) {
      put('00$i.txt', 'bad');
    }
    await drainer((item) async => throw StateError('engine down')).run();
    expect(ClipQueue.inCooldown, isTrue);

    put('900.txt', 'the user just copied this');
    final attempted = <String>[];

    await drainer((item) async {
      attempted.add(item.name!);
      if (item.text == 'bad') throw StateError('engine down');
    }).run();

    expect(attempted, ['900.txt'],
        reason: 'the five known-bad clips must NOT be re-read and re-written — '
            'that is exactly what the hold is holding off');
  });

  /// A file that can never be turned into a clip (corrupt bytes, flaky flash) is
  /// never "tried" in the ordinary sense — and if that makes it look like
  /// untried work forever, the cooldown becomes a permanent no-op and the
  /// requeue->inotify->drain spin comes straight back.
  test('an UNREADABLE file does not turn the cooldown into a no-op', () async {
    put('001.txt', 'bad');
    await drainer((item) async => throw StateError('engine down')).run();
    expect(ClipQueue.inCooldown, isTrue);

    // A file drain() cannot materialize — and aged, like any backlog clip. (The
    // real shape is not a corrupt byte: it is a 25MB screenshot that OOMs while
    // being read in the memory-tight service isolate.)
    final unreadable = File('${tmp.path}/002.txt')
      ..writeAsBytesSync([0xC3, 0x28, 0x41]) // invalid UTF-8
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
    var attempts = 0;

    await drainer((item) async => attempts++).run();

    expect(attempts, 0,
        reason: 'a file that cannot even be read is not "untried work" — '
            'treating it as such makes every cooldown a no-op, forever');
    expect(unreadable.existsSync(), isTrue,
        reason: 'and it must NOT be deleted for failing to read: an age gate '
            'keys off when the clip was WRITTEN, so it would destroy a good '
            'screenshot captured an hour ago on its first transient read error '
            '— the one path in this codebase that would DELETE a clip rather '
            'than park it');
  });

  /// The full cycle, and the thing that must never happen: the known-bad backlog
  /// is DEFERRED while the hold stands, but never STRANDED. Once the hold
  /// expires and the engine recovers, every one of those clips must sync.
  test('the deferred backlog is retried once the hold expires — never stranded',
      () async {
    for (var i = 1; i <= 5; i++) {
      put('00$i.txt', 'clip-$i');
    }
    var engineUp = false;

    // The engine is down: the backlog fails and earns a hold.
    await drainer((item) async {
      if (!engineUp) throw StateError('engine down');
    }).run();
    expect(ClipQueue.inCooldown, isTrue);

    // The user copies something. It syncs (the bypass) — but that must NOT
    // forgive the hold, or the next run drags all five back through a sick disk.
    put('900.txt', 'fresh');
    await drainer((item) async {
      if (!engineUp && item.text != 'fresh') throw StateError('engine down');
    }).run();
    expect(ClipQueue.inCooldown, isTrue,
        reason: 'a run that skipped the backlog proves nothing about it');

    // The hold expires and the engine recovers.
    engineUp = true;
    ClipQueue.expireCooldownForTests();
    final synced = <String>[];
    await drainer((item) async => synced.add(item.name!)).run();

    expect(synced, hasLength(5),
        reason: 'deferred is not stranded — every clip must sync in the end');
    expect(onDisk(), isEmpty);
  });

  test('a clip that threw is rescued when the link drops immediately after',
      () async {
    put('001.txt', 'a');
    put('002.txt', 'b');
    put('003.txt', 'c');
    var up = true;

    await drainer(
      (item) async {
        if (item.text == 'a') {
          up = false; // the socket died: the send throws AND the link is gone
          throw StateError('socket closed');
        }
      },
      canContinue: () => up,
    ).run();

    expect(onDisk(), ['001.txt', '002.txt', '003.txt'],
        reason: 'the FAILED clip and the un-attempted tail must BOTH be back on '
            'disk — a finally that only rescues items[i..] silently destroys the '
            'one that threw');
    expect(tmp.listSync().where((f) => f.path.endsWith('.dead')), isEmpty);
  });

  test('a LONG total outage does not bleed good clips into quarantine one by '
      'one', () async {
    for (var i = 1; i <= 5; i++) {
      put('00$i.txt', 'clip-$i');
    }
    for (var run = 0; run < 6; run++) {
      ClipQueue.noteDrainSuccess(); // cooldowns expire; the outage persists
      await drainer((item) async => throw StateError('disk full')).run();
    }

    expect(tmp.listSync().where((f) => f.path.endsWith('.dead')), isEmpty,
        reason: 'five clips failing TOGETHER is evidence for a broken engine, '
            'not against any one of them — parking the oldest every 10 minutes '
            'is just a slower shredder');
    expect(onDisk().where((n) => n.endsWith('.txt')), hasLength(5));
  });

  test('an empty drain does NOT forgive the backoff (the other isolate may be '
      'mid-batch, having already deleted the files)', () async {
    ClipQueue.noteDrainFailure();
    ClipQueue.expireCooldownForTests(); // the hold lapses; the failure stands
    expect(ClipQueue.drainFailures, 1);

    // Nothing on disk: this drain observes nothing, so it proves nothing.
    await drainer((item) async {}).run();

    expect(ClipQueue.drainFailures, 1,
        reason: '"the directory looks empty" is not evidence that the engine '
            'works — only a fully delivered batch is. Resetting here lets the '
            'two isolates keep each other at the 15s floor forever.');

    // A batch that actually goes through IS evidence.
    put('001.txt', 'a');
    await drainer((item) async {}).run();
    expect(ClipQueue.drainFailures, 0);
  });

  test('if PARKING the clip fails too, it goes back on the queue — "could not '
      'save it" must never become "deleted it"', () async {
    put('001.txt', 'poison');
    // Make the .dead write fail the way a full disk would (the same fault that
    // most plausibly broke the engine in the first place): something is already
    // in the way of that exact path.
    Directory('${tmp.path}/001.txt.dead').createSync();

    for (var run = 0; run < 4; run++) {
      put('90$run.txt', 'good'); // proves the engine works, so 001 is blamed
      ClipQueue.noteDrainSuccess();
      await drainer((item) async {
        if (item.text == 'poison') throw StateError('unprocessable');
      }).run();
    }

    expect(File('${tmp.path}/001.txt').existsSync(), isTrue,
        reason: 'quarantine() could not write the clip, so the drainer must put '
            'it back — drain() already deleted the original, so swallowing that '
            'failure destroys it');
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
