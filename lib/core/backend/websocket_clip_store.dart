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
  // (handshake in flight, socket half-open, between reconnects) and flushed
  // when the server answers. Bounded; oldest dropped first. Entries older
  // than [_staleEditAge] at flush time are dropped, not replayed — a
  // destructive edit from hours ago must not wipe clips other devices added
  // since (the user saw it not take effect and moved on).
  static const _maxPending = 200;
  static const _staleEditAge = Duration(minutes: 10);
  final List<({String frame, DateTime at})> _pending = [];

  // At-least-once delivery for clips. A send can vanish two ways: buffered
  // while visibly disconnected, or written into a socket that is already dead
  // but not yet detected (~2× the transport ping interval). So every append is
  // kept here, keyed by content hash, until the server PROVES it has it — our
  // own clip comes back on the room broadcast, or its hash appears in a
  // reconnect's history snapshot. Whatever is still unproven after a reconnect
  // is resent — EXCEPT entries already sent once that have aged past
  // [_staleResendAge]: those almost certainly arrived (only the echo was
  // lost), and resending hours later would re-stamp stale content as the
  // room's newest clip on every device. Never-sent entries survive any age —
  // an offline-overnight copy must still sync. Bounded by entry count AND
  // total bytes (an image frame can be tens of MB); oldest evicted first.
  static const _staleResendAge = Duration(minutes: 10);
  final int _maxUnacked;
  final int _maxUnackedBytes;
  final Map<String, ({String frame, DateTime? firstSentAt})> _unacked = {};
  int _unackedBytes = 0;

  // Mirror of the relay's ciphertext cap: the server silently drops larger
  // clip frames (bare return — no error, no echo), so sending one would park
  // it in _unacked forever and re-upload it on every reconnect: a poison pill.
  final int _maxCiphertextChars;

  final DateTime Function() _clock;

  final List<RemoteClip> _history = [];
  final _historyController = StreamController<List<RemoteClip>>.broadcast();
  final _incomingController = StreamController<RemoteClip>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();
  bool _connected = false;

  WebSocketClipStore({
    required this.roomToken,
    required RelayTransport Function() transportFactory,
    DateTime Function()? clock,
    int maxUnacked = 30,
    int maxUnackedBytes = 32 << 20,
    int maxCiphertextChars = 64000000,
  })  : _transportFactory = transportFactory,
        _clock = clock ?? DateTime.now,
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
        case 'history':
          _history
            ..clear()
            ..addAll((msg['clips'] as List).map(_parse));
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
  /// [_unacked] until the server proves receipt, and resent after a reconnect
  /// otherwise — so a copy made while the link is down (or half-open) syncs
  /// when the connection comes back instead of silently vanishing.
  Future<void> append(EncryptedClip clip) async {
    // The relay silently drops frames past its ciphertext cap — sending one
    // would just poison _unacked (re-uploaded forever, never acked).
    if (clip.ciphertext.length > _maxCiphertextChars) return;
    final frame = jsonEncode({'type': 'clip', 'clip': clip.toMap()});
    final t = _transport;
    final sendNow = _connected && t != null;
    // Remove-then-insert so a re-copied clip becomes the NEWEST entry: a
    // plain re-assign keeps its original LinkedHashMap position, making the
    // user's most recent copy the first one evicted under pressure.
    _untrackUnacked(clip.hash);
    _unacked[clip.hash] =
        (frame: frame, firstSentAt: sendNow ? _clock() : null);
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
    final e = _unacked.remove(hash);
    if (e != null) _unackedBytes -= e.frame.length;
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
      _pending.add((frame: message, at: _clock()));
    }
  }

  void _flushPending() {
    final t = _transport;
    if (t == null || _pending.isEmpty) return;
    final now = _clock();
    final batch = List.of(_pending);
    _pending.clear();
    for (final e in batch) {
      // A destructive edit buffered hours ago must not replay against a room
      // whose content moved on — the user saw it not take effect.
      if (now.difference(e.at) > _staleEditAge) continue;
      t.send(e.frame);
    }
  }

  /// After a reconnect's snapshot: drop tracked clips the server already has
  /// (hash present in history), drop sent-once entries that aged past the
  /// resend window (they almost certainly arrived; resending would re-stamp
  /// stale content as the room's newest), resend the rest.
  void _resendUnacked() {
    final t = _transport;
    if (t == null || _unacked.isEmpty) return;
    final have = _history.map((c) => c.hash).toSet();
    for (final h in _unacked.keys.where(have.contains).toList()) {
      _untrackUnacked(h);
    }
    final now = _clock();
    for (final h in _unacked.keys.toList()) {
      final e = _unacked[h]!;
      final sentAt = e.firstSentAt;
      if (sentAt != null && now.difference(sentAt) > _staleResendAge) {
        _untrackUnacked(h);
        continue;
      }
      _unacked[h] = (frame: e.frame, firstSentAt: sentAt ?? now);
      t.send(e.frame);
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
