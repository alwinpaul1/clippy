import 'dart:convert';
import 'dart:io';

import 'package:clippy_relay/relay.dart';
import 'package:test/test.dart';

/// Durability contract of [FileClipRepository]: adds may ride the debounce
/// (bounded write amplification under clip bursts), but destructive edits and
/// [FileClipRepository.flush] must reach the disk without waiting for it —
/// the relay is SIGTERM-killed on every deploy, and anything still inside the
/// window at that moment is silently lost (adds) or resurrected (deletes).
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('clippy-repo-test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, dynamic> clip(String t) => {'ciphertext': 'enc:$t', 'hash': 'h:$t'};

  List<dynamic> onDisk(String path, String room) {
    final f = File(path);
    if (!f.existsSync()) return const [];
    final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    return (data[room] as List?) ?? const [];
  }

  Future<void> until(bool Function() done, String what) async {
    for (var i = 0; i < 100; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('not durable within 2s: $what');
  }

  test('adds are debounced, but flush() makes them durable immediately',
      () async {
    final path = '${tmp.path}/clips.json';
    final repo =
        FileClipRepository(path, persistDelay: const Duration(minutes: 10));
    repo.add('r', clip('a'));
    expect(onDisk(path, 'r'), isEmpty,
        reason: 'still inside the coalescing window — nothing on disk yet');
    await repo.flush();
    expect(onDisk(path, 'r').map((c) => c['hash']), ['h:a'],
        reason: 'flush() is the SIGTERM path — it must not wait the debounce');
  });

  test('a remove is durable without waiting for the debounce window',
      () async {
    final path = '${tmp.path}/clips.json';
    final repo =
        FileClipRepository(path, persistDelay: const Duration(minutes: 10));
    repo.add('r', clip('secret'));
    await repo.flush();
    repo.remove('r', {'h:secret'});
    await until(() => onDisk(path, 'r').isEmpty,
        'a deleted clip must not survive a crash inside the debounce window');
  });

  test('a clear is durable without waiting for the debounce window', () async {
    final path = '${tmp.path}/clips.json';
    final repo =
        FileClipRepository(path, persistDelay: const Duration(minutes: 10));
    repo.add('r', clip('x'));
    await repo.flush();
    repo.clear('r');
    await until(() => onDisk(path, 'r').isEmpty,
        'cleared clips must not resurrect after a redeploy');
  });

  test('flush() during a pending debounce persists the latest state',
      () async {
    final path = '${tmp.path}/clips.json';
    final repo =
        FileClipRepository(path, persistDelay: const Duration(minutes: 10));
    repo.add('r', clip('one'));
    repo.add('r', clip('two'));
    await repo.flush();
    expect(onDisk(path, 'r').map((c) => c['hash']), ['h:one', 'h:two']);
  });
}
