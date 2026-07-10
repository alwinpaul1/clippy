import 'dart:async';
import 'dart:convert';

import '../models/encrypted_clip.dart';
import '../models/remote_clip.dart';
import 'relay_transport.dart';

/// Client for the Clippy relay. Joins a room, keeps the room's clip history in
/// order, streams incoming clips, and **auto-reconnects** with exponential
/// backoff (re-joining and refreshing history on each reconnect). The relay
/// routes only E2E-encrypted payloads by opaque room token, so this class never
/// handles plaintext.
///
/// The transport is injected as a factory so it is unit-testable without a
/// socket; [WebSocketClipStore.connect] wires it to a real WebSocket.
class WebSocketClipStore {
  static const _minBackoffMs = 500;
  static const _maxBackoffMs = 15000;

  final String roomToken;
  final RelayTransport Function() _transportFactory;

  RelayTransport? _transport;
  StreamSubscription<String>? _sub;
  bool _closed = false;
  int _backoffMs = _minBackoffMs;

  // Outbound delete/clear frames held while the link isn't confirmed
  // (handshake in flight, socket half-open, between reconnects) and ALWAYS
  // replayed when it is — the UI confirms deletes to the user immediately
  // ("Clip deleted" / "gone for good"), so dropping a buffered edit would
  // silently resurrect content the user was told is gone. Bounded; oldest
  // dropped first.
  static const _maxPending = 200;
  final List<String> _pending = [];

  // At-least-once delivery for clips. A send can vanish two ways: buffered
  // while visibly disconnected, or written into a socket that is already dead
  // but not yet detected (~2× the transport ping interval). Every append is
  // kept here, keyed by content hash, until the relay's explicit 'ack' frame
  // proves delivery ('reject' proves it can never succeed); whatever is still
  // unproven after a reconnect is resent. Resending is idempotent — the relay
  // moves an existing hash to the top instead of duplicating it — so no age
  // guessing is needed. Bounded by entry count AND total bytes (an image
  // frame can be tens of MB); oldest evicted first.
  final int _maxUnacked;
  final int _maxUnackedBytes;
  final Map<String, String> _unacked = {}; // content hash → clip frame
  int _unackedBytes = 0;

  // Mirror of the relay's ciphertext cap: nothing above it can ever be
  // stored, so don't build or send the frame at all.
  final int _maxCiphertextChars;

  final List<RemoteClip> _history = [];
  final _historyController = StreamController<List<RemoteClip>>.broadcast();
  final _incomingController = StreamController<RemoteClip>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();
  bool _connected = false;

  WebSocketClipStore({
    required this.roomToken,
    required RelayTransport Function() transportFactory,
    int maxUnacked = 30,
    int maxUnackedBytes = 32 << 20,
    int maxCiphertextChars = 64000000,
  })  : _transportFactory = transportFactory,
        _maxUnacked = maxUnacked,
        _maxUnackedBytes = maxUnackedBytes,
        _maxCiphertextChars = maxCiphertextChars {
    _open();
  }

  factory WebSocketClipStore.connect(Uri url, String roomToken) =>
      WebSocketClipStore(
        roomToken: roomToken,
        transportFactory: () => WebSocketRelayTransport(url),
      );

  /// The full ordered room history, re-emitted whenever it changes.
  Stream<List<RemoteClip>> get history => _historyController.stream;

  /// Each clip as it arrives (newest), for the SyncEngine's apply decision.
  Stream<RemoteClip> get incoming => _incomingController.stream;

  /// Connection status changes (true = connected, false = reconnecting).
  Stream<bool> get connected => _connectedController.stream;
  bool get isConnected => _connected;

  /// The current history snapshot.
  List<RemoteClip> get current => List.unmodifiable(_history);

  void _open() {
    final transport = _transportFactory();
    _transport = transport;
    _sub = transport.messages.listen(
      _onMessage,
      onDone: _onDrop,
      onError: (_) => _onDrop(),
      cancelOnError: true,
    );
    transport.send(jsonEncode({'type': 'join', 'room': roomToken}));
    // NOT connected yet: the socket may still be handshaking (or already
    // dead). The relay answers every join with a history frame — only that
    // reply proves the link, and _onMessage flips the flag.
  }

  void _onDrop() {
    _sub?.cancel();
    _transport = null; // sends must buffer now, not vanish into a dead sink
    if (_closed) return;
    _setConnected(false);
    final delay = _backoffMs;
    _backoffMs = (_backoffMs * 2).clamp(_minBackoffMs, _maxBackoffMs);
    Timer(Duration(milliseconds: delay), () {
      if (!_closed) _open();
    });
  }

  void _setConnected(bool value) {
    _connected = value;
    if (!_connectedController.isClosed) _connectedController.add(value);
  }

  void _onMessage(String raw) {
    _backoffMs = _minBackoffMs; // healthy traffic resets backoff
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      // Unparseable — do NOT flip connected on it: only a real (parsed) frame
      // may, or the justConnected flush below would be skipped and buffered
      // clips would sit stranded for this connection's whole lifetime.
      return;
    }
    // First parsed frame after (re)opening is the join reply — only a
    // received frame proves the link is real (a socket can look open while
    // dead).
    final justConnected = !_connected;
    if (justConnected) _setConnected(true);
    try {
      switch (msg['type']) {
        case 'ack': // relay stored our clip — delivery proven
        case 'reject': // relay will never store it — stop resending
          final h = msg['hash'];
          if (h is String) _untrackUnacked(h);
        case 'history':
          // Parse the WHOLE snapshot before touching _history: one malformed
          // entry must not leave a cleared/partial history behind (the
          // justConnected resend below reads it as the set of proven clips).
          final clips = (msg['clips'] as List).map(_parse).toList();
          _history
            ..clear()
            ..addAll(clips);
          _emitHistory();
          // Catch-up apply: surface the newest clip as incoming so anything
          // copied while we were offline lands on the clipboard at reconnect.
          // The engine's persisted lastAppliedHash dedups repeat emissions.
          if (_history.isNotEmpty) _incomingController.add(_history.last);
        case 'clip':
          final clip = _parse(msg['clip']);
          _untrackUnacked(clip.hash); // our own broadcast = server has it
          if (_history.isEmpty || _history.last.hash != clip.hash) {
            _history.add(clip);
            _emitHistory();
          }
          _incomingController.add(clip);
        case 'deleted':
          final hashes =
              (msg['hashes'] as List?)?.whereType<String>().toSet() ??
              const <String>{};
          hashes.forEach(_untrackUnacked); // deleted — never resend it
          if (hashes.isNotEmpty) {
            _history.removeWhere((c) => hashes.contains(c.hash));
            _emitHistory();
          }
        case 'cleared':
          _untrackAllUnacked();
          if (_history.isNotEmpty) {
            _history.clear();
            _emitHistory();
          }
      }
    } catch (_) {
      // A malformed field inside an otherwise-parsed frame (bad timestamp,
      // wrong shape) — drop the frame; never let it kill the socket
      // subscription or escape to the zone.
    } finally {
      if (justConnected) {
        // AFTER the snapshot is applied (even if its handler threw): send
        // what queued while we were dark, resend what the server can't
        // prove it has.
        _flushPending();
        _resendUnacked();
      }
    }
  }

  RemoteClip _parse(dynamic m) {
    final map = (m as Map).cast<String, dynamic>();
    return RemoteClip.fromMap(
      map,
      // Relay stamps UTC; show it in THIS device's local timezone so the
      // displayed time/date matches wherever Clippy is installed.
      timestamp: DateTime.parse(map['timestamp'] as String).toLocal(),
    );
  }

  void _emitHistory() {
    if (!_historyController.isClosed) {
      _historyController.add(List.unmodifiable(_history));
    }
  }

  /// Send a sealed clip to the room. At-least-once: the frame is tracked in
  /// [_unacked] until the relay acks it, and resent after a reconnect
  /// otherwise — so a copy made while the link is down (or half-open) syncs
  /// when the connection comes back instead of silently vanishing.
  Future<void> append(EncryptedClip clip) async {
    // Nothing above the relay's ciphertext cap can ever be stored — don't
    // build or send a frame that would only be rejected.
    if (clip.ciphertext.length > _maxCiphertextChars) return;
    final frame = jsonEncode({'type': 'clip', 'clip': clip.toMap()});
    final t = _transport;
    final sendNow = _connected && t != null;
    // A frame too large for the resend budget must not be ADMITTED to it:
    // tracking it would evict the entire never-sent backlog chasing the byte
    // bound. Best-effort send instead — the relay accepts it; it just carries
    // no resend guarantee.
    if (frame.length > _maxUnackedBytes) {
      if (sendNow) t.send(frame);
      return;
    }
    // Remove-then-insert so a re-copied clip becomes the NEWEST entry: a
    // plain re-assign keeps its original LinkedHashMap position, making the
    // user's most recent copy the first one evicted under pressure.
    _untrackUnacked(clip.hash);
    _unacked[clip.hash] = frame;
    _unackedBytes += frame.length;
    while (_unacked.length > 1 &&
        (_unacked.length > _maxUnacked || _unackedBytes > _maxUnackedBytes)) {
      _untrackUnacked(_unacked.keys.first);
    }
    if (sendNow) t.send(frame);
  }

  /// Ask the room to delete clips by content hash. The server broadcasts the
  /// deletion back to every device (including this one), which applies it.
  Future<void> deleteHashes(Iterable<String> hashes) async {
    final list = hashes.toList();
    if (list.isEmpty) return;
    // The user deleted these — never resend them, even if the server never
    // held them (offline delete) or the frame below is lost.
    list.forEach(_untrackUnacked);
    _send(jsonEncode({'type': 'delete', 'hashes': list}));
  }

  /// Clear the whole room history for all devices.
  Future<void> clearAll() async {
    _untrackAllUnacked(); // cleared clips must never be resent
    _send(jsonEncode({'type': 'clear'}));
  }

  void _untrackUnacked(String hash) {
    final frame = _unacked.remove(hash);
    if (frame != null) _unackedBytes -= frame.length;
  }

  void _untrackAllUnacked() {
    _unacked.clear();
    _unackedBytes = 0;
  }

  void _send(String message) {
    final t = _transport;
    if (_connected && t != null) {
      t.send(message);
    } else {
      if (_pending.length >= _maxPending) _pending.removeAt(0);
      _pending.add(message);
    }
  }

  void _flushPending() {
    final t = _transport;
    if (t == null || _pending.isEmpty) return;
    final batch = List.of(_pending);
    _pending.clear();
    for (final m in batch) {
      t.send(m);
    }
  }

  /// After a reconnect's snapshot: drop tracked clips the snapshot already
  /// proves delivered (supplementary to the ack, and the old-relay fallback),
  /// then resend the rest. Safe at any age: the relay dedups by hash
  /// (move-to-top), so a resend can never create a duplicate entry.
  void _resendUnacked() {
    final t = _transport;
    if (t == null || _unacked.isEmpty) return;
    final have = _history.map((c) => c.hash).toSet();
    for (final h in _unacked.keys.toList()) {
      if (have.contains(h)) {
        _untrackUnacked(h);
      } else {
        t.send(_unacked[h]!);
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    await _transport?.close();
    await _historyController.close();
    await _incomingController.close();
    await _connectedController.close();
  }
}
