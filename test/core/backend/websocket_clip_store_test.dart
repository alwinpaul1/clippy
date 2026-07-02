import 'dart:async';
import 'dart:convert';

import 'package:clippy/core/backend/websocket_clip_store.dart';
import 'package:clippy/core/models/encrypted_clip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<String> incoming;
  late List<String> sent;

  WebSocketClipStore build() => WebSocketClipStore(
        incoming: incoming.stream,
        send: sent.add,
        roomToken: 'ROOM',
      );

  String historyMsg(List<String> texts) => jsonEncode({
        'type': 'history',
        'clips': [
          for (final t in texts)
            {
              'ciphertext': 'enc:$t',
              'iv': 'iv',
              'hash': 'h:$t',
              'source': 'devX',
              'timestamp': '2026-07-02T00:00:00.000Z',
            }
        ],
      });

  String clipMsg(String text, {String source = 'devX'}) => jsonEncode({
        'type': 'clip',
        'clip': {
          'ciphertext': 'enc:$text',
          'iv': 'iv',
          'hash': 'h:$text',
          'source': source,
          'timestamp': '2026-07-02T00:00:01.000Z',
        },
      });

  setUp(() {
    incoming = StreamController<String>();
    sent = [];
  });

  test('sends a join with the room token on construction', () {
    build();
    expect(sent, hasLength(1));
    expect(jsonDecode(sent.single), {'type': 'join', 'room': 'ROOM'});
  });

  test('a history message becomes an ordered history snapshot', () async {
    final store = build();
    final future = store.history.first;
    incoming.add(historyMsg(['a', 'b']));
    final snapshot = await future;
    expect(snapshot.map((c) => c.ciphertext).toList(), ['enc:a', 'enc:b']);
    expect(snapshot.first.timestamp, DateTime.utc(2026, 7, 2));
  });

  test('an incoming clip is appended to history and emitted on incoming',
      () async {
    final store = build();
    final incomingFuture = store.incoming.first;
    final historyFuture =
        store.history.firstWhere((h) => h.any((c) => c.hash == 'h:new'));
    incoming.add(clipMsg('new'));
    final clip = await incomingFuture;
    expect(clip.ciphertext, 'enc:new');
    final h = await historyFuture;
    expect(h.last.ciphertext, 'enc:new');
  });

  test('a clip with the same hash as the newest is not double-added', () async {
    final store = build();
    incoming.add(historyMsg(['dup']));
    await store.history.first;
    incoming.add(clipMsg('dup')); // same hash as newest
    // Give the event loop a turn.
    await Future<void>.delayed(Duration.zero);
    expect(store.current.where((c) => c.hash == 'h:dup').length, 1);
  });

  test('append sends a clip frame carrying the sealed payload', () async {
    final store = build();
    sent.clear();
    await store.append(const EncryptedClip(
        ciphertext: 'enc:x', iv: 'iv', hash: 'h:x', source: 'me'));
    expect(jsonDecode(sent.single), {
      'type': 'clip',
      'clip': {'ciphertext': 'enc:x', 'iv': 'iv', 'hash': 'h:x', 'source': 'me'},
    });
  });
}
