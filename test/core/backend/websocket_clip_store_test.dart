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
    transports[0].emit(historyMsg([])); // server confirms the join
    await store.connected.firstWhere((up) => up);
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

  // The relay answers every join with a history frame, so a received message
  // is the only proof the link is really up — a socket can be half-open (or
  // still handshaking) while looking locally fine.
  test('isConnected stays false until the server replies to the join',
      () async {
    final store = build();
    expect(store.isConnected, isFalse);
    transports[0].emit(historyMsg([]));
    await store.connected.firstWhere((up) => up);
    expect(store.isConnected, isTrue);
  });

  test('an append before the server confirms is buffered, then flushed',
      () async {
    final store = build();
    await store.append(const EncryptedClip(
        ciphertext: 'enc:q', iv: 'iv', hash: 'h:q', source: 'me'));
    // Not confirmed yet — only the join frame may be on the wire.
    expect(transports[0].sent.map((m) => jsonDecode(m)['type']),
        isNot(contains('clip')));

    transports[0].emit(historyMsg([]));
    await store.connected.firstWhere((up) => up);
    final types = transports[0].sent.map((m) => jsonDecode(m)['type']);
    expect(types, contains('clip'), reason: 'buffered append must flush');
  });

  group('at-least-once hardening (1.0.25)', () {
    WebSocketClipStore buildWith({
      int maxUnacked = 30,
      int maxUnackedBytes = 32 << 20,
      int maxCiphertextChars = 64000000,
    }) =>
        WebSocketClipStore(
          roomToken: 'ROOM',
          transportFactory: () {
            final t = FakeTransport();
            transports.add(t);
            return t;
          },
          maxUnacked: maxUnacked,
          maxUnackedBytes: maxUnackedBytes,
          maxCiphertextChars: maxCiphertextChars,
        );

    EncryptedClip clip(String text) => EncryptedClip(
        ciphertext: 'enc:$text', iv: 'iv', hash: 'h:$text', source: 'me');

    Future<void> connect(WebSocketClipStore store, FakeTransport t) async {
      t.emit(historyMsg([]));
      await store.connected.firstWhere((up) => up);
    }

    List<String> clipHashesSentOn(FakeTransport t) => [
          for (final m in t.sent.map(jsonDecode))
            if (m['type'] == 'clip') m['clip']['hash'] as String,
        ];

    test('a clip deleted while offline is NOT resent on reconnect', () async {
      final store = buildWith();
      await store.append(clip('x')); // offline — tracked, unsent
      await store.deleteHashes(['h:x']); // user deletes it, still offline
      await connect(store, transports[0]);
      expect(clipHashesSentOn(transports[0]), isNot(contains('h:x')),
          reason: 'deleting a clip must purge it from the resend set');
    });

    test('clips cleared while offline are NOT resent on reconnect', () async {
      final store = buildWith();
      await store.append(clip('a'));
      await store.append(clip('b'));
      await store.clearAll(); // still offline
      await connect(store, transports[0]);
      expect(clipHashesSentOn(transports[0]), isEmpty,
          reason: 'clear-all must purge the resend set');
    });

    test('a malformed first frame does not strand the buffers', () async {
      final store = buildWith();
      await store.append(clip('q')); // buffered while unconfirmed
      transports[0].emit('not-json{{{'); // garbage first frame
      await Future<void>.delayed(Duration.zero);
      transports[0].emit(historyMsg([])); // then the real join reply
      await store.connected.firstWhere((up) => up);
      expect(clipHashesSentOn(transports[0]), contains('h:q'),
          reason: 'the flush must still happen on this connection');
    });

    test('re-copying a clip makes it newest for eviction, not oldest',
        () async {
      final store = buildWith(maxUnacked: 3);
      await store.append(clip('a')); // oldest
      await store.append(clip('b'));
      await store.append(clip('c')); // full
      await store.append(clip('a')); // re-copied — must become newest
      await store.append(clip('d')); // evicts the true oldest (b), not a
      await connect(store, transports[0]);
      final sent = clipHashesSentOn(transports[0]);
      expect(sent, contains('h:a'),
          reason: 'the just-re-copied clip must survive eviction');
      expect(sent, isNot(contains('h:b')),
          reason: 'the genuinely oldest entry is the one evicted');
    });

    test('an oversized clip is never sent or tracked (poison pill)', () async {
      final store = buildWith(maxCiphertextChars: 10);
      await store.append(clip('this-is-way-past-ten-chars'));
      await connect(store, transports[0]);
      expect(clipHashesSentOn(transports[0]), isEmpty,
          reason: 'the relay would silently drop it — never send or resend');
    });

    test('every unacked clip is resent on reconnect — sent-once and '
        'never-sent alike, at any age', () async {
      final store = buildWith();
      await connect(store, transports[0]);
      await store.append(clip('sent')); // sent while connected, no ack came
      transports[0].drop();
      await Future<void>.delayed(Duration.zero);
      await store.append(clip('unsent')); // buffered while down

      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(transports, hasLength(2));
      await connect(store, transports[1]);

      final resent = clipHashesSentOn(transports[1]);
      expect(resent, containsAll(['h:sent', 'h:unsent']),
          reason: 'no ack = no proof of delivery = resend (the relay dedups '
              'by hash, so a resend can never duplicate)');
    });

    test('a buffered delete replays on reconnect — the UI already confirmed '
        'the deletion to the user', () async {
      final store = buildWith();
      await store.deleteHashes(['h:old']); // buffered while offline
      await connect(store, transports[0]);
      final types = transports[0].sent.map((m) => jsonDecode(m)['type']);
      expect(types, contains('delete'),
          reason: "'Clip deleted' was shown — the intent must reach the room");
    });

    test("the relay's ack purges the resend set", () async {
      final store = buildWith();
      await connect(store, transports[0]);
      await store.append(clip('proven'));
      transports[0].emit(jsonEncode({'type': 'ack', 'hash': 'h:proven'}));
      await Future<void>.delayed(Duration.zero);

      transports[0].drop();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await connect(store, transports[1]); // empty history — no snapshot proof
      expect(clipHashesSentOn(transports[1]), isEmpty,
          reason: 'acked clips must not resend even with no snapshot proof');
    });

    test("the relay's reject purges the resend set (no poison pill)",
        () async {
      final store = buildWith();
      await connect(store, transports[0]);
      await store.append(clip('doomed'));
      transports[0].emit(jsonEncode({'type': 'reject', 'hash': 'h:doomed'}));
      await Future<void>.delayed(Duration.zero);

      transports[0].drop();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await connect(store, transports[1]);
      expect(clipHashesSentOn(transports[1]), isEmpty,
          reason: 'a rejected clip can never succeed — stop re-uploading it');
    });

    test('a frame past the byte budget is sent best-effort, never admitted '
        'to evict the backlog', () async {
      // Small text frames are ~115 chars of JSON; the jumbo's is ~900.
      final store = buildWith(maxUnackedBytes: 400);
      await connect(store, transports[0]);
      transports[0].drop();
      await Future<void>.delayed(Duration.zero);
      await store.append(clip('small-a')); // never-sent backlog
      await store.append(clip('small-b'));

      await Future<void>.delayed(const Duration(milliseconds: 700));
      await connect(store, transports[1]);
      await store.append(clip('jumbo-${'z' * 400}')); // frame > 200 budget

      final t1 = clipHashesSentOn(transports[1]);
      expect(t1.any((h) => h.startsWith('h:jumbo')), isTrue,
          reason: 'jumbo still sent while connected (best-effort)');
      expect(t1, containsAll(['h:small-a', 'h:small-b']),
          reason: 'the never-sent backlog must survive the jumbo append');

      transports[1].drop();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await connect(store, transports[2]);
      expect(clipHashesSentOn(transports[2]).any((h) => h.startsWith('h:jumbo')),
          isFalse,
          reason: 'jumbo carries no resend guarantee — it was never tracked');
    });

    test('a malformed history entry leaves the previous snapshot intact',
        () async {
      final store = buildWith();
      transports[0].emit(historyMsg(['keep']));
      await store.connected.firstWhere((up) => up);
      expect(store.current.single.hash, 'h:keep');

      transports[0].emit(jsonEncode({
        'type': 'history',
        'clips': [
          {
            'ciphertext': 'enc:bad',
            'iv': 'iv',
            'hash': 'h:bad',
            'source': 'devX',
            'timestamp': 'not-a-date', // DateTime.parse throws
          }
        ],
      }));
      await Future<void>.delayed(Duration.zero);
      expect(store.current.single.hash, 'h:keep',
          reason: 'a throwing parse must not clear or truncate the history');
    });

    test('unacked is bounded by total bytes, evicting oldest first', () async {
      // Each frame is ~230 chars of JSON: two fit the 500 budget, three don't
      // (and none trips the per-frame admission guard).
      final store = buildWith(maxUnackedBytes: 500);
      await store.append(clip('one-${'x' * 60}'));
      await store.append(clip('two-${'y' * 60}'));
      await store.append(clip('three-${'z' * 60}')); // pushes total past 500
      await connect(store, transports[0]);
      final sent = clipHashesSentOn(transports[0]);
      expect(sent.any((h) => h.startsWith('h:three')), isTrue);
      expect(sent.any((h) => h.startsWith('h:one')), isFalse,
          reason: 'oldest entry evicted to hold the byte budget');
    });
  });

  test('an append during a drop is delivered on the next connection',
      () async {
    final store = build();
    transports[0].emit(historyMsg([]));
    await store.connected.firstWhere((up) => up);

    transports[0].drop(); // connection dies
    await store.append(const EncryptedClip(
        ciphertext: 'enc:lost?', iv: 'iv', hash: 'h:lost?', source: 'me'));

    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(transports, hasLength(2), reason: 'should have reconnected');
    transports[1].emit(historyMsg([]));
    await store.connected.firstWhere((up) => up);

    final types = transports[1].sent.map((m) => jsonDecode(m)['type']).toList();
    expect(types, contains('clip'),
        reason: 'the clip appended while offline must arrive, not vanish');
    await store.close();
  });
}
