import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clippy_relay/relay.dart';
import 'package:test/test.dart';

/// Connects a WebSocket client and exposes decoded messages as a broadcast
/// stream for easy awaiting in tests.
Future<(WebSocket, Stream<Map<String, dynamic>>)> connect(int port) async {
  final ws = await WebSocket.connect('ws://localhost:$port');
  final stream = ws
      .map((d) => jsonDecode(d as String) as Map<String, dynamic>)
      .asBroadcastStream();
  return (ws, stream);
}

Map<String, dynamic> clipMsg(String text, {String source = 'devA'}) => {
      'type': 'clip',
      'clip': {
        'ciphertext': 'enc:$text',
        'iv': 'iv',
        'hash': 'h:$text',
        'source': source,
      },
    };

void main() {
  late HttpServer server;
  int port() => server.port;

  setUp(() async {
    repository = InMemoryClipRepository();
    roomClients.clear();
    nowIso = () => '2026-07-02T00:00:00.000Z';
    maxCiphertextChars = 64000000; // production value; tests may shrink it
    server = await startServer(0);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('health endpoint responds ok', () async {
    final res = await HttpClient().getUrl(Uri.parse('http://localhost:${port()}/health')).then((r) => r.close());
    expect(res.statusCode, 200);
  });

  test('a clip from one device reaches another in the same room', () async {
    final (a, _) = await connect(port());
    final (b, bStream) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'room-1'}));
    b.add(jsonEncode({'type': 'join', 'room': 'room-1'}));
    // Drain each client's initial history frame.
    await bStream.first; // history

    a.add(jsonEncode(clipMsg('hello')));
    final received = await bStream.firstWhere((m) => m['type'] == 'clip');
    expect(received['clip']['ciphertext'], 'enc:hello');
    expect(received['clip']['source'], 'devA');
    expect(received['clip']['timestamp'], '2026-07-02T00:00:00.000Z');

    await a.close();
    await b.close();
  });

  test('sender also receives its own clip, server-stamped (echo to all)',
      () async {
    final (a, aStream) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'solo'}));
    await aStream.first; // history

    a.add(jsonEncode(clipMsg('mine')));
    final echoed = await aStream.firstWhere((m) => m['type'] == 'clip');
    expect(echoed['clip']['ciphertext'], 'enc:mine');
    expect(echoed['clip']['timestamp'], '2026-07-02T00:00:00.000Z');
    await a.close();
  });

  test('a stored clip is acked to the sender (delivery proof)', () async {
    final (a, aStream) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'ack-room'}));
    await aStream.first; // history

    a.add(jsonEncode(clipMsg('proof')));
    final ack = await aStream.firstWhere((m) => m['type'] == 'ack');
    expect(ack['hash'], 'h:proof');
    await a.close();
  });

  test('an oversized clip is rejected to the sender, not silently dropped',
      () async {
    // Shrink the cap for the fixture: materializing the real 64M-char cap
    // (plus its jsonEncode/decode copies) costs hundreds of MB per run.
    maxCiphertextChars = 1000;
    final (a, aStream) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'fat-room'}));
    await aStream.first; // history

    a.add(jsonEncode({
      'type': 'clip',
      'clip': {
        'ciphertext': 'x' * (maxCiphertextChars + 1),
        'iv': 'iv',
        'hash': 'h:fat',
        'source': 'devA',
      },
    }));
    final reject = await aStream.firstWhere((m) => m['type'] == 'reject');
    expect(reject['hash'], 'h:fat');
    expect(repository.recent('fat-room'), isEmpty);
    await a.close();
  });

  test('a clip without a hash is dropped, not stored', () async {
    final (a, aStream) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'nohash'}));
    await aStream.first; // history

    a.add(jsonEncode({
      'type': 'clip',
      'clip': {'ciphertext': 'enc:x', 'iv': 'iv', 'source': 'devA'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(repository.recent('nohash'), isEmpty,
        reason: 'a hashless clip can never be acked, deduped, or deleted — '
            'and storing it would let null == null purge every other '
            'hashless clip via the move-to-top removeWhere');
    await a.close();
  });

  test('re-sending an existing hash moves it to the top, no duplicate entry',
      () async {
    final (a, aStream) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'dup-room'}));
    await aStream.first; // history

    a.add(jsonEncode(clipMsg('one')));
    await aStream.firstWhere((m) => m['type'] == 'ack');
    a.add(jsonEncode(clipMsg('two')));
    await aStream.firstWhere(
        (m) => m['type'] == 'ack' && m['hash'] == 'h:two');
    // Resend 'one' (a client that lost the ack) — must not duplicate.
    a.add(jsonEncode(clipMsg('one')));
    await aStream.firstWhere(
        (m) => m['type'] == 'ack' && m['hash'] == 'h:one');

    final hashes =
        repository.recent('dup-room').map((c) => c['hash']).toList();
    expect(hashes, ['h:two', 'h:one'],
        reason: 'moved to top, not appended as a duplicate');
    await a.close();
  });

  test('a device joining later receives room history', () async {
    final (a, _) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'r'}));
    a.add(jsonEncode(clipMsg('first')));
    a.add(jsonEncode(clipMsg('second')));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final (b, bStream) = await connect(port());
    b.add(jsonEncode({'type': 'join', 'room': 'r'}));
    final history = await bStream.firstWhere((m) => m['type'] == 'history');
    final texts =
        (history['clips'] as List).map((c) => c['ciphertext']).toList();
    expect(texts, ['enc:first', 'enc:second']);

    await a.close();
    await b.close();
  });

  test('devices in different rooms are isolated', () async {
    final (a, _) = await connect(port());
    final (b, bStream) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'room-A'}));
    b.add(jsonEncode({'type': 'join', 'room': 'room-B'}));
    await bStream.first; // history

    a.add(jsonEncode(clipMsg('secret')));
    final leaked = await bStream
        .firstWhere((m) => m['type'] == 'clip')
        .timeout(const Duration(milliseconds: 300), onTimeout: () => {})
        .then((m) => m.isNotEmpty);
    expect(leaked, isFalse, reason: 'room-B must not see room-A clips');

    await a.close();
    await b.close();
  });

  test('history is capped and collapses consecutive duplicate hashes', () async {
    final (a, _) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'cap'}));
    // Two identical, then one different.
    a.add(jsonEncode(clipMsg('dup')));
    a.add(jsonEncode(clipMsg('dup')));
    a.add(jsonEncode(clipMsg('other')));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final (b, bStream) = await connect(port());
    b.add(jsonEncode({'type': 'join', 'room': 'cap'}));
    final history = await bStream.firstWhere((m) => m['type'] == 'history');
    final texts =
        (history['clips'] as List).map((c) => c['ciphertext']).toList();
    expect(texts, ['enc:dup', 'enc:other']);

    await a.close();
    await b.close();
  });

  test('delete removes a clip and broadcasts to all room members', () async {
    final (a, _) = await connect(port());
    final (b, bStream) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'del'}));
    b.add(jsonEncode({'type': 'join', 'room': 'del'}));
    await bStream.first; // history

    a.add(jsonEncode(clipMsg('keep')));
    a.add(jsonEncode(clipMsg('drop')));
    await bStream.where((m) => m['type'] == 'clip').take(2).toList();

    a.add(jsonEncode({'type': 'delete', 'hashes': ['h:drop']}));
    final deleted = await bStream.firstWhere((m) => m['type'] == 'deleted');
    expect(deleted['hashes'], ['h:drop']);
    expect(
      repository.recent('del').map((c) => c['hash']).toList(),
      ['h:keep'],
    );

    await a.close();
    await b.close();
  });

  test('clear empties the room and broadcasts cleared', () async {
    final (a, aStream) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'clr'}));
    await aStream.first; // history
    a.add(jsonEncode(clipMsg('x')));
    await aStream.firstWhere((m) => m['type'] == 'clip');

    a.add(jsonEncode({'type': 'clear'}));
    final cleared = await aStream.firstWhere((m) => m['type'] == 'cleared');
    expect(cleared['type'], 'cleared');
    expect(repository.recent('clr'), isEmpty);

    await a.close();
  });

  test('an emptied room with no connected devices is reclaimed on disconnect',
      () async {
    final (a, aStream) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'temp'}));
    await aStream.first; // history
    a.add(jsonEncode(clipMsg('x')));
    await aStream.firstWhere((m) => m['type'] == 'clip');
    a.add(jsonEncode({'type': 'clear'})); // room now empty, A still connected
    await aStream.firstWhere((m) => m['type'] == 'cleared');

    await a.close(); // last device leaves an empty room
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect((repository as InMemoryClipRepository).rooms.containsKey('temp'),
        isFalse, reason: 'empty pairing code should be reclaimed');
    expect(roomClients.containsKey('temp'), isFalse); // no leaked client set
  });

  test('a room that still has clips is kept when its last device disconnects',
      () async {
    final (a, aStream) = await connect(port());
    a.add(jsonEncode({'type': 'join', 'room': 'persist'}));
    await aStream.first; // history
    a.add(jsonEncode(clipMsg('keep')));
    await aStream.firstWhere((m) => m['type'] == 'clip');

    await a.close(); // no devices connected now, but they may be offline
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(roomClients.containsKey('persist'), isFalse);
    expect(repository.recent('persist').map((c) => c['hash']).toList(),
        ['h:keep'], reason: 'history must survive when devices are only offline');
  });
}
