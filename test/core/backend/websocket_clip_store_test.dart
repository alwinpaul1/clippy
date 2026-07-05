import 'dart:async';
import 'dart:convert';

import 'package:clippy/core/backend/relay_transport.dart';
import 'package:clippy/core/backend/websocket_clip_store.dart';
import 'package:clippy/core/models/encrypted_clip.dart';
import 'package:flutter_test/flutter_test.dart';

/// Controllable in-memory transport for tests.
class FakeTransport implements RelayTransport {
  final _controller = StreamController<String>();
  final List<String> sent = [];
  bool closed = false;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  void send(String message) => sent.add(message);

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  void emit(String message) => _controller.add(message);
  void drop() => _controller.close(); // fires onDone → triggers reconnect
}

void main() {
  late List<FakeTransport> transports;

  WebSocketClipStore build() => WebSocketClipStore(
        roomToken: 'ROOM',
        transportFactory: () {
          final t = FakeTransport();
          transports.add(t);
          return t;
        },
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

  setUp(() => transports = []);

  test('sends a join with the room token on construction', () {
    build();
    expect(transports, hasLength(1));
    expect(jsonDecode(transports[0].sent.single), {'type': 'join', 'room': 'ROOM'});
  });

  test('a history message becomes an ordered history snapshot', () async {
    final store = build();
    final future = store.history.first;
    transports[0].emit(historyMsg(['a', 'b']));
    final snapshot = await future;
    expect(snapshot.map((c) => c.ciphertext).toList(), ['enc:a', 'enc:b']);
    // Timestamps are converted to local time for display (same instant).
    expect(snapshot.first.timestamp, DateTime.utc(2026, 7, 2).toLocal());
  });

  test('an incoming clip is appended to history and emitted on incoming',
      () async {
    final store = build();
    final incomingFuture = store.incoming.first;
    final historyFuture =
        store.history.firstWhere((h) => h.any((c) => c.hash == 'h:new'));
    transports[0].emit(clipMsg('new'));
    expect((await incomingFuture).ciphertext, 'enc:new');
    expect((await historyFuture).last.ciphertext, 'enc:new');
  });

  test('a clip with the same hash as the newest is not double-added', () async {
    final store = build();
    transports[0].emit(historyMsg(['dup']));
    await store.history.first;
    transports[0].emit(clipMsg('dup'));
    await Future<void>.delayed(Duration.zero);
    expect(store.current.where((c) => c.hash == 'h:dup').length, 1);
  });

  test('append sends a clip frame carrying the sealed payload', () async {
    final store = build();
    transports[0].sent.clear();
    await store.append(const EncryptedClip(
        ciphertext: 'enc:x', iv: 'iv', hash: 'h:x', source: 'me'));
    expect(jsonDecode(transports[0].sent.single), {
      'type': 'clip',
      'clip': {
        'ciphertext': 'enc:x',
        'iv': 'iv',
        'hash': 'h:x',
        'source': 'me',
        'device': '',
        'kind': 'text',
        'mime': '',
      },
    });
  });

  test('reconnects and rejoins after the transport drops', () async {
    final store = build();
    expect(transports, hasLength(1));
    final drops = <bool>[];
    store.connected.listen(drops.add);

    transports[0].drop(); // connection lost
    // Wait past the minimum backoff (500ms).
    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(transports, hasLength(2), reason: 'should have reconnected');
    expect(jsonDecode(transports[1].sent.single)['type'], 'join',
        reason: 'should rejoin the room');
    expect(drops, contains(false), reason: 'should report disconnect');
    await store.close();
  });

  test('refreshNow forces an immediate reconnect and re-joins (no backoff wait)',
      () async {
    final store = build();
    expect(transports, hasLength(1));

    store.refreshNow(); // e.g. app returned to foreground
    expect(transports, hasLength(2),
        reason: 'reconnects immediately, not after backoff');
    expect(jsonDecode(transports[1].sent.single)['type'], 'join',
        reason: 'the fresh socket re-joins the room (refreshing history)');
    expect(transports[0].closed, isTrue, reason: 'old socket is torn down');

    // Debounced: a second refresh within 2s must NOT thrash a new socket.
    store.refreshNow();
    expect(transports, hasLength(2), reason: 'debounced within 2s');
    await store.close();
  });
}
