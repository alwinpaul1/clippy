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

  final List<RemoteClip> _history = [];
  final _historyController = StreamController<List<RemoteClip>>.broadcast();
  final _incomingController = StreamController<RemoteClip>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();
  bool _connected = false;

  WebSocketClipStore({
    required this.roomToken,
    required RelayTransport Function() transportFactory,
  }) : _transportFactory = transportFactory {
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
    _setConnected(true);
  }

  void _onDrop() {
    _sub?.cancel();
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
      return;
    }
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
        if (_history.isEmpty || _history.last.hash != clip.hash) {
          _history.add(clip);
          _emitHistory();
        }
        _incomingController.add(clip);
      case 'deleted':
        final hashes =
            (msg['hashes'] as List?)?.whereType<String>().toSet() ??
            const <String>{};
        if (hashes.isNotEmpty) {
          _history.removeWhere((c) => hashes.contains(c.hash));
          _emitHistory();
        }
      case 'cleared':
        if (_history.isNotEmpty) {
          _history.clear();
          _emitHistory();
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

  /// Send a sealed clip to the room.
  Future<void> append(EncryptedClip clip) async =>
      _transport?.send(jsonEncode({'type': 'clip', 'clip': clip.toMap()}));

  /// Ask the room to delete clips by content hash. The server broadcasts the
  /// deletion back to every device (including this one), which applies it.
  Future<void> deleteHashes(Iterable<String> hashes) async {
    final list = hashes.toList();
    if (list.isEmpty) return;
    _transport?.send(jsonEncode({'type': 'delete', 'hashes': list}));
  }

  /// Clear the whole room history for all devices.
  Future<void> clearAll() async =>
      _transport?.send(jsonEncode({'type': 'clear'}));

  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    await _transport?.close();
    await _historyController.close();
    await _incomingController.close();
    await _connectedController.close();
  }
}
