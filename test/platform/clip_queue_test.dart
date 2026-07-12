import 'dart:io';

import 'package:clippy/platform/clip_queue.dart';
import 'package:flutter_test/flutter_test.dart';

/// Host-side tests for the on-disk clip queue (normally Android-only; the
/// [ClipQueue.debugDir] hook points it at a temp directory instead).
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('clippy-queue-test');
    ClipQueue.debugDir = tmp;
    ClipQueue.resetForTests(); // no strike/cooldown bleed between tests
  });

  tearDown(() {
    ClipQueue.debugDir = null;
    ClipQueue.maxQueueFiles = 200;
    ClipQueue.maxQueueBytes = 200 << 20;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File put(String name, String content) =>
      File('${tmp.path}/$name')..writeAsStringSync(content);

  /// Queue files are prunable only after [ClipQueue]'s per-file age gate —
  /// back-date a fixture so the bound applies to it.
  File aged(String name, String content) => put(name, content)
    ..setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));

  // The drain heartbeat is bookkeeping, not a clip — never count it.
  List<String> queued() => tmp
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n != 'drain.beat')
      .toList()
    ..sort();

  test('drain consumes queued text oldest-first and leaves nothing behind',
      () async {
    put('001.txt', 'hello');
    put('002.txt', 'world');
    final items = await ClipQueue.drain();
    expect(items.map((i) => i.text).toList(), ['hello', 'world']);
    expect(queued(), isEmpty);
  });

  test('enforceBound drops the oldest aged files beyond the count bound',
      () async {
    ClipQueue.maxQueueFiles = 2;
    aged('001.txt', 'a');
    aged('002.txt', 'b');
    aged('003.txt', 'c');
    await ClipQueue.enforceBound();
    expect(queued(), ['002.txt', '003.txt'],
        reason: 'oldest first — newer captures are worth more');
  });

  test('fresh files are structurally unprunable — a requeue landing mid-'
      'enforcement (either isolate) cannot be deleted', () async {
    ClipQueue.maxQueueFiles = 1;
    aged('001.txt', 'old-overflow');
    put('002.txt', 'just-requeued'); // fresh mtime = the safety, no lock file
    put('003.txt', 'just-captured');
    await ClipQueue.enforceBound();
    expect(queued(), ['002.txt', '003.txt'],
        reason: 'per-file age replaces the shared drain.lock: a fresh write '
            'carries its own protection, with no heartbeat one isolate can '
            'delete out from under the other');
  });

  test('enforceBound reaps stale .part orphans (exempt from the bound, but '
      'not allowed to grow forever)', () async {
    final orphan = put('img.png.part', 'x' * 10)
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));
    final fresh = put('img2.png.part', 'y'); // mid-write — must survive
    await ClipQueue.enforceBound();
    expect(orphan.existsSync(), isFalse,
        reason: 'the drain-side reaper never runs while offline — the only '
            'time enforceBound runs — so it must reap here too');
    expect(fresh.existsSync(), isTrue);
  });

  test('drain returns a bounded BATCH — a huge backlog is not read into memory '
      'all at once', () async {
    ClipQueue.maxDrainFiles = 3;
    addTearDown(() => ClipQueue.maxDrainFiles = 30);
    for (var i = 1; i <= 7; i++) {
      put('00$i.txt', 'clip-$i');
    }

    final first = await ClipQueue.drain();
    expect(first.map((i) => i.text), ['clip-1', 'clip-2', 'clip-3'],
        reason: 'oldest first, capped');
    expect(queued().where((f) => f.endsWith('.txt')), hasLength(4),
        reason: 'the tail must stay ON DISK — the only crash-proof copy');

    final second = await ClipQueue.drain();
    expect(second.map((i) => i.text), ['clip-4', 'clip-5', 'clip-6']);
  });

  test('a live drain stops enforceBound pruning the tail it is about to '
      'deliver', () async {
    ClipQueue.maxQueueFiles = 1;
    aged('001.txt', 'undelivered');
    aged('002.txt', 'undelivered too');
    // A drain in EITHER isolate refreshes the heartbeat; the pruner (whose own
    // link may be down) must stand down while it runs.
    File('${tmp.path}/drain.beat').writeAsStringSync('');

    await ClipQueue.enforceBound();

    expect(queued(), containsAll(['001.txt', '002.txt']),
        reason: 'pruning is oldest-first — exactly the batches the drain is '
            'about to take');
  });

  test('a STALE heartbeat (the drainer died) does not disable the bound '
      'forever', () async {
    ClipQueue.maxQueueFiles = 1;
    aged('001.txt', 'a');
    aged('002.txt', 'b');
    File('${tmp.path}/drain.beat')
      ..writeAsStringSync('')
      ..setLastModifiedSync(
          DateTime.now().subtract(const Duration(minutes: 5)));

    await ClipQueue.enforceBound();

    expect(queued(), isNot(contains('001.txt')),
        reason: 'a heartbeat nobody refreshes is a crash leftover, not a drain '
            '— and unlike the old lock it is never deleted, so staleness is '
            'the only way it can expire');
  });

  test('three strikes park a clip; a success wipes the slate', () {
    // noteItemFailure is ONLY ever called from an engine-proven run — a failure
    // with nothing delivered is indistinguishable from a broken engine and is
    // never counted, which is what stops a backlog being blamed for an outage.
    expect(ClipQueue.noteItemFailure('a.txt'), isFalse);
    expect(ClipQueue.noteItemFailure('a.txt'), isFalse);
    expect(ClipQueue.noteItemFailure('a.txt'), isTrue);

    expect(ClipQueue.noteItemFailure('b.txt'), isFalse);
    ClipQueue.clearFailures('b.txt');
    expect(ClipQueue.noteItemFailure('b.txt'), isFalse,
        reason: 'a transient failure must never accumulate toward poison');
  });

  test('a failed drain backs off, so a GLOBAL fault cannot burn through the '
      'backlog in one loop', () async {
    ClipQueue.noteDrainSuccess();
    expect(ClipQueue.inCooldown, isFalse);

    ClipQueue.noteDrainFailure();

    expect(ClipQueue.inCooldown, isTrue,
        reason: 'the engine failing (prefs write, crypto, OOM) means EVERY '
            'item would fail — the drain must stop and wait, not prove it 200 '
            'more times and delete the queue');
    ClipQueue.noteDrainSuccess();
    expect(ClipQueue.inCooldown, isFalse, reason: 'a success clears the hold');
  });

  test('parking renames the clip to .dead — it is never rewritten, never lost, '
      'and never re-drained', () async {
    put('001.txt', 'unprocessable');

    expect(await ClipQueue.parkFile('001.txt'), isTrue);

    expect(File('${tmp.path}/001.txt.dead').existsSync(), isTrue,
        reason: 'an atomic rename: nothing is held in memory, nothing rewritten');
    expect(File('${tmp.path}/001.txt').existsSync(), isFalse);
    expect(await ClipQueue.drain(), isEmpty,
        reason: 'a parked clip must not be re-read (it would come back as '
            'garbage and fail forever)');
  });

  test('a park that fails leaves the clip exactly where it was — still queued',
      () async {
    put('001.txt', 'unprocessable');
    Directory('${tmp.path}/001.txt.dead').createSync(); // rename will fail

    expect(await ClipQueue.parkFile('001.txt'), isFalse);
    expect(File('${tmp.path}/001.txt').existsSync(), isTrue,
        reason: '"could not park it" must never become "deleted it"');
  });

  test('parked clips are reaped after a day, not hoarded', () async {
    put('002.txt', 'old');
    await ClipQueue.parkFile('002.txt');
    File('${tmp.path}/002.txt.dead').setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 2)));
    put('003.txt', 'recent');
    await ClipQueue.parkFile('003.txt');

    await ClipQueue.enforceBound();

    expect(File('${tmp.path}/002.txt.dead').existsSync(), isFalse);
    expect(File('${tmp.path}/003.txt.dead').existsSync(), isTrue);
  });

  test('a failed delete is not counted as freed space', () async {
    ClipQueue.maxQueueFiles = 1;
    final immovable = aged('001.txt', 'x');
    aged('002.txt', 'y');
    aged('003.txt', 'z');
    Process.runSync('chflags', ['uchg', immovable.path]);
    addTearDown(() => Process.runSync('chflags', ['nouchg', immovable.path]));

    await ClipQueue.enforceBound();

    expect(immovable.existsSync(), isTrue); // undeletable, still here
    expect(File('${tmp.path}/002.txt').existsSync(), isFalse);
    expect(File('${tmp.path}/003.txt').existsSync(), isFalse,
        reason: 'phantom accounting for the failed delete would stop the '
            'loop early and leave the queue over its bound');
  }, skip: !Platform.isMacOS ? 'chflags is macOS-only' : false);
}
