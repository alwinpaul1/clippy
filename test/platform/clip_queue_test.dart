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

  List<String> queued() => tmp
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .toList()
    ..sort();

  test('drain consumes queued text oldest-first and leaves nothing behind',
      () async {
    put('001.txt', 'hello');
    put('002.txt', 'world');
    final items = await ClipQueue.drain();
    expect(items.map((i) => i.text).toList(), ['hello', 'world']);
    expect(queued(), isEmpty,
        reason: 'consumed files AND the drain lock must both be gone');
  });

  test('enforceBound drops the oldest files beyond the count bound', () async {
    ClipQueue.maxQueueFiles = 2;
    put('001.txt', 'a');
    put('002.txt', 'b');
    put('003.txt', 'c');
    await ClipQueue.enforceBound();
    expect(queued(), ['002.txt', '003.txt'],
        reason: 'oldest first — newer captures are worth more');
  });

  test('enforceBound is a no-op while a drain lock is fresh (an active '
      'drain/requeue in ANY isolate owns the directory)', () async {
    ClipQueue.maxQueueFiles = 2;
    put('001.txt', 'a');
    put('002.txt', 'b');
    put('003.txt', 'c');
    put('drain.lock', '');
    await ClipQueue.enforceBound();
    expect(queued(), contains('001.txt'),
        reason: 'pruning under a live drain can delete files the drainer '
            'just requeued or was about to deliver');
  });

  test('a stale drain lock (crashed drainer) does not disable the bound',
      () async {
    ClipQueue.maxQueueFiles = 2;
    put('001.txt', 'a');
    put('002.txt', 'b');
    put('003.txt', 'c');
    put('drain.lock', '').setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 5)));
    await ClipQueue.enforceBound();
    expect(queued(), isNot(contains('001.txt')),
        reason: 'a lock nobody refreshes is a crash leftover, not a drain');
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

  test('a failed delete is not counted as freed space', () async {
    ClipQueue.maxQueueFiles = 1;
    final immovable = put('001.txt', 'x');
    put('002.txt', 'y');
    put('003.txt', 'z');
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
