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

  /// Queue files are prunable only after [ClipQueue]'s per-file age gate —
  /// back-date a fixture so the bound applies to it.
  File aged(String name, String content) => put(name, content)
    ..setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));

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
