@TestOn('vm')
library;

import 'dart:io';

import 'package:clippy/core/backend/websocket_clip_store.dart';
import 'package:clippy/core/models/encrypted_clip.dart';
import 'package:clippy_relay/relay.dart' as relay;
import 'package:flutter_test/flutter_test.dart';

/// End-to-end: two real WebSocketClipStore clients talking to the real relay
/// running in-process. Proves the client and server protocols agree.
void main() {
  late HttpServer server;
  Uri url() => Uri.parse('ws://localhost:${server.port}');

  setUp(() async {
    relay.repository = relay.InMemoryClipRepository();
    relay.roomClients.clear();
    server = await relay.startServer(0);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  EncryptedClip clip(String text, {String source = 'A'}) => EncryptedClip(
      ciphertext: 'enc:$text', iv: 'iv', hash: 'h:$text', source: source);

  test('a clip appended on one client reaches another in the same room',
      () async {
    final a = WebSocketClipStore.connect(url(), 'room-x');
    final b = WebSocketClipStore.connect(url(), 'room-x');
    await Future<void>.delayed(const Duration(milliseconds: 150)); // joins

    final bIncoming = b.incoming.first;
    await a.append(clip('hi'));
    final received = await bIncoming.timeout(const Duration(seconds: 5));

    expect(received.ciphertext, 'enc:hi');
    expect(received.source, 'A');
    expect(received.timestamp, isA<DateTime>());

    await a.close();
    await b.close();
  });

  test('a client joining later receives existing room history', () async {
    final a = WebSocketClipStore.connect(url(), 'room-h');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await a.append(clip('one'));
    await a.append(clip('two'));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    final b = WebSocketClipStore.connect(url(), 'room-h');
    final history =
        await b.history.first.timeout(const Duration(seconds: 5));
    expect(history.map((c) => c.ciphertext).toList(), ['enc:one', 'enc:two']);

    await a.close();
    await b.close();
  });

  test('different rooms are isolated', () async {
    final a = WebSocketClipStore.connect(url(), 'room-A');
    final b = WebSocketClipStore.connect(url(), 'room-B');
    await Future<void>.delayed(const Duration(milliseconds: 150));

    var leaked = false;
    final sub = b.incoming.listen((_) => leaked = true);
    await a.append(clip('secret'));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(leaked, isFalse);
    await sub.cancel();
    await a.close();
    await b.close();
  });
}
