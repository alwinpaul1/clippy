import 'dart:convert';
import 'dart:io';

import 'package:clippy_relay/relay.dart';
import 'package:test/test.dart';

Map<String, dynamic> clip(String t) =>
    {'ciphertext': 'enc:$t', 'iv': 'iv', 'hash': 'h:$t', 'source': 'a'};

void main() {
  group('repository', () {
    late InMemoryClipRepository repo;
    setUp(() => repo = InMemoryClipRepository());

    test('a pinned clip is never evicted by new clips', () {
      repo.add('r', clip('keep'));
      expect(repo.setPinned('r', 'h:keep', true), isTrue);
      for (var i = 0; i < maxHistory + 10; i++) {
        repo.add('r', clip('n$i'));
      }
      final hashes = repo.recent('r').map((c) => c['hash']).toList();
      expect(hashes, contains('h:keep'));
      // Pins do not count toward the cap: still maxHistory unpinned clips.
      expect(hashes.length, maxHistory + 1);
    });

    test('a re-copy of a pinned clip moves up and stays pinned', () {
      repo.add('r', clip('x'));
      repo.setPinned('r', 'h:x', true);
      repo.add('r', clip('y'));
      repo.add('r', clip('x'));
      final x = repo.recent('r').last;
      expect(x['hash'], 'h:x');
      expect(x['pinned'], isTrue);
    });

    test('unpin, no-op and unknown hash', () {
      repo.add('r', clip('x'));
      expect(repo.setPinned('r', 'h:x', false), isFalse, reason: 'already unpinned');
      expect(repo.setPinned('r', 'h:nope', true), isFalse);
      repo.setPinned('r', 'h:x', true);
      expect(repo.setPinned('r', 'h:x', false), isTrue);
      expect(repo.recent('r').single.containsKey('pinned'), isFalse);
    });

    test('pins are capped at maxPinned', () {
      for (var i = 0; i < maxPinned; i++) {
        repo.add('r', clip('p$i'));
        expect(repo.setPinned('r', 'h:p$i', true), isTrue);
      }
      repo.add('r', clip('p$maxPinned'));
      expect(repo.setPinned('r', 'h:p$maxPinned', true), isFalse);
    });
  });

  group('protocol', () {
    late HttpServer server;
    setUp(() async {
      repository = InMemoryClipRepository();
      roomClients.clear();
      roomTombstones.clear();
      nowIso = () => '2026-07-02T00:00:00.000Z';
      server = await startServer(0);
    });
    tearDown(() => server.close(force: true));

    Future<(WebSocket, Stream<Map<String, dynamic>>)> join() async {
      final ws = await WebSocket.connect('ws://localhost:${server.port}');
      final s = ws.map((d) => jsonDecode(d as String) as Map<String, dynamic>).asBroadcastStream();
      ws.add(jsonEncode({'type': 'join', 'room': 'room'}));
      await s.firstWhere((m) => m['type'] == 'history');
      return (ws, s);
    }

    test('a pin reaches every device and survives Clear all', () async {
      final (a, aS) = await join();
      final (b, bS) = await join();
      a.add(jsonEncode({'type': 'clip', 'clip': clip('keep')}));
      a.add(jsonEncode({'type': 'clip', 'clip': clip('gone')}));
      await bS.where((m) => m['type'] == 'clip').take(2).toList();

      a.add(jsonEncode({'type': 'pin', 'hash': 'h:keep', 'pinned': true}));
      final pin = await bS.firstWhere((m) => m['type'] == 'pinned');
      expect(pin['hash'], 'h:keep');
      expect(pin['pinned'], isTrue);

      a.add(jsonEncode({'type': 'clear', 'before': '2026-07-02T00:00:00.000Z'}));
      final del = await bS.firstWhere((m) => m['type'] == 'deleted');
      expect(del['hashes'], ['h:gone']);
      expect(repository.recent('room').map((c) => c['hash']), ['h:keep']);

      // A fresh join's snapshot carries the flag.
      final (c, _) = await join();
      expect(repository.recent('room').single['pinned'], isTrue);
      await Future.wait([a.close(), b.close(), c.close()]);
      await aS.drain<void>().catchError((_) {});
    });

    test('an explicit delete still removes a pinned clip', () async {
      final (a, aS) = await join();
      a.add(jsonEncode({'type': 'clip', 'clip': clip('p')}));
      await aS.firstWhere((m) => m['type'] == 'clip');
      a.add(jsonEncode({'type': 'pin', 'hash': 'h:p', 'pinned': true}));
      await aS.firstWhere((m) => m['type'] == 'pinned');
      a.add(jsonEncode({'type': 'delete', 'hashes': ['h:p']}));
      await aS.firstWhere((m) => m['type'] == 'deleted');
      expect(repository.recent('room'), isEmpty);
      await a.close();
    });

    test('a pin over the cap is rejected back to the sender', () async {
      // Pin each as it lands: unpinned, the 26th clip would evict the first.
      for (var i = 0; i < maxPinned; i++) {
        repository.add('room', clip('p$i'));
        repository.setPinned('room', 'h:p$i', true);
      }
      repository.add('room', clip('p$maxPinned'));
      final (a, aS) = await join();
      a.add(jsonEncode({'type': 'pin', 'hash': 'h:p$maxPinned', 'pinned': true}));
      final r = await aS.firstWhere((m) => m['type'] == 'pin-rejected');
      expect(r['hash'], 'h:p$maxPinned');
      await a.close();
    });
  });
}
