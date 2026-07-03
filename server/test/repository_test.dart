import 'dart:io';

import 'package:clippy_relay/relay.dart';
import 'package:test/test.dart';

Map<String, dynamic> clip(String t) => {
      'ciphertext': 'enc:$t',
      'iv': 'iv',
      'hash': 'h:$t',
      'source': 's',
      'timestamp': 't',
    };

void main() {
  test('InMemory collapses consecutive dupes and caps at maxHistory', () {
    final r = InMemoryClipRepository();
    r.add('room', clip('a'));
    r.add('room', clip('a')); // duplicate hash
    r.add('room', clip('b'));
    expect(r.recent('room').map((c) => c['hash']).toList(), ['h:a', 'h:b']);

    for (var i = 0; i < 40; i++) {
      r.add('room', clip('x$i'));
    }
    expect(r.recent('room').length, maxHistory);
  });

  test('remove drops clips by hash and reports what it removed', () {
    final r = InMemoryClipRepository();
    r.add('room', clip('a'));
    r.add('room', clip('b'));
    r.add('room', clip('c'));

    final removed = r.remove('room', {'h:b', 'h:missing'});
    expect(removed, ['h:b']); // only the hash that existed
    expect(r.recent('room').map((c) => c['hash']).toList(), ['h:a', 'h:c']);
  });

  test('clear empties a room', () {
    final r = InMemoryClipRepository();
    r.add('room', clip('a'));
    r.add('room', clip('b'));
    r.clear('room');
    expect(r.recent('room'), isEmpty);
  });

  test('File repository persists removes and clears across restart', () async {
    final dir = await Directory.systemTemp.createTemp('clippy_relay_rm');
    final path = '${dir.path}/clippy.json';
    try {
      FileClipRepository(path)
        ..add('room', clip('a'))
        ..add('room', clip('b'))
        ..remove('room', {'h:a'});
      expect(
        FileClipRepository(path).recent('room').map((c) => c['hash']).toList(),
        ['h:b'],
      );

      FileClipRepository(path).clear('room');
      expect(FileClipRepository(path).recent('room'), isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('File history survives a new instance on the same path (restart)',
      () async {
    final dir = await Directory.systemTemp.createTemp('clippy_relay_test');
    final path = '${dir.path}/clippy.json';
    try {
      FileClipRepository(path)
        ..add('room', clip('one'))
        ..add('room', clip('two'));

      final restarted = FileClipRepository(path);
      expect(restarted.recent('room').map((c) => c['hash']).toList(),
          ['h:one', 'h:two']);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('File repository tolerates an unwritable path without crashing', () {
    final r = FileClipRepository('/dev/null/relay.json');
    r.add('room', clip('a')); // must not throw
    expect(r.recent('room').single['hash'], 'h:a'); // served from memory
  });
}
