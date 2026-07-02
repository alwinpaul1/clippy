import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/encrypted_clip.dart';
import '../models/remote_clip.dart';

/// Client for the Clippy relay. Joins a room, keeps the room's clip history in
/// order, and streams incoming clips. The relay routes only E2E-encrypted
/// payloads by opaque room token, so this class never handles plaintext.
///
/// The primary constructor takes an injected message channel so it is unit
/// testable without a socket; [WebSocketClipStore.connect] wires it to a real
/// WebSocket.
class WebSocketClipStore {
  final void Function(String) _send;
  final Future<void> Function()? _closer;

  final List<RemoteClip> _history = [];
  final _historyController = StreamController<List<RemoteClip>>.broadcast();
  final _incomingController = StreamController<RemoteClip>.broadcast();
  late final StreamSubscription<String> _sub;

  WebSocketClipStore({
    required Stream<String> incoming,
    required void Function(String) send,
    required String roomToken,
    Future<void> Function()? closer,
  })  : _send = send,
        _closer = closer {
    _sub = incoming.listen(_onMessage, cancelOnError: false);
    _send(jsonEncode({'type': 'join', 'room': roomToken}));
  }

  factory WebSocketClipStore.connect(Uri url, String roomToken) {
    final channel = WebSocketChannel.connect(url);
    return WebSocketClipStore(
      incoming: channel.stream.map((d) => d as String),
      send: channel.sink.add,
      roomToken: roomToken,
      closer: () => channel.sink.close(),
    );
  }

  /// The full ordered room history, re-emitted whenever it changes.
  Stream<List<RemoteClip>> get history => _historyController.stream;

  /// Each clip as it arrives (newest), for the SyncEngine's apply decision.
  Stream<RemoteClip> get incoming => _incomingController.stream;

  /// The current history snapshot.
  List<RemoteClip> get current => List.unmodifiable(_history);

  void _onMessage(String raw) {
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
      case 'clip':
        final clip = _parse(msg['clip']);
        if (_history.isEmpty || _history.last.hash != clip.hash) {
          _history.add(clip);
          _emitHistory();
        }
        _incomingController.add(clip);
    }
  }

  RemoteClip _parse(dynamic m) {
    final map = (m as Map).cast<String, dynamic>();
    return RemoteClip.fromMap(
      map,
      timestamp: DateTime.parse(map['timestamp'] as String),
    );
  }

  void _emitHistory() =>
      _historyController.add(List.unmodifiable(_history));

  /// Send a sealed clip to the room.
  Future<void> append(EncryptedClip clip) async =>
      _send(jsonEncode({'type': 'clip', 'clip': clip.toMap()}));

  Future<void> close() async {
    await _sub.cancel();
    await _closer?.call();
    await _historyController.close();
    await _incomingController.close();
  }
}
