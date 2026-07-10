import 'dart:convert';
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

    // Insert past the cap whatever its value, so this test keeps exercising
    // eviction if maxHistory changes again.
    for (var i = 0; i < maxHistory + 15; i++) {
      r.add('room', clip('x$i'));
    }
    expect(r.recent('room').length, maxHistory);
    // Oldest evicted first: the earliest survivor is the (15+2)th insert
    // ('a' and 'b' plus x0..x14 fell off), and the newest insert is last.
    expect(r.recent('room').first['hash'], 'h:x15');
    expect(r.recent('room').last['hash'], 'h:x${maxHistory + 14}');
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

  test('delete removes the room key entirely (not just its clips)', () {
    final r = InMemoryClipRepository();
    r.add('roomA', clip('a'));
    r.add('roomB', clip('b'));
    r.delete('roomA');
    expect(r.rooms.containsKey('roomA'), isFalse); // key gone, not just emptied
    expect(r.recent('roomB').single['hash'], 'h:b'); // other rooms untouched
  });

  test('startup drops empty rooms left in the persisted file', () async {
    final dir = await Directory.systemTemp.createTemp('clippy_relay_gc');
    final path = '${dir.path}/clippy.json';
    try {
      // Simulate a file where one room was cleared to empty (its key lingered)
      // while another still holds clips.
      FileClipRepository(path)
        ..add('live', clip('keep'))
        ..add('dead', clip('gone'))
        ..clear('dead'); // leaves 'dead' present but empty on disk
      // Precondition read the raw file (a fresh repo would already sweep it).
      final onDisk = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(onDisk.containsKey('dead'), isTrue);
      expect((onDisk['dead'] as List), isEmpty);

      final restarted = FileClipRepository(path);
      expect(restarted.rooms.containsKey('dead'), isFalse); // swept on load
      expect(restarted.recent('live').single['hash'], 'h:keep'); // kept
      // The sweep rewrote the file, so it's clean too.
      final rewritten = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(rewritten.containsKey('dead'), isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
