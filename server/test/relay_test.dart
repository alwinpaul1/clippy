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
    rooms.clear();
    nowIso = () => '2026-07-02T00:00:00.000Z';
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
}
