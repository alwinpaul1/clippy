import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A single relay connection's message channel. Abstracted so the reconnecting
/// [WebSocketClipStore] can be unit-tested with a fake transport.
abstract class RelayTransport {
  Stream<String> get messages;
  void send(String message);
  Future<void> close();
}

class WebSocketRelayTransport implements RelayTransport {
  final WebSocketChannel _channel;

  /// [pingInterval] is what keeps sync feeling instant. Without it, a HALF-OPEN
  /// socket (laptop wakes from sleep, Wi-Fi hop, NAT idle-timeout) still looks
  /// connected but silently delivers nothing — so a clip / delete / clear-all
  /// broadcast never arrives until TCP eventually times out (minutes of stale
  /// history). With a 10s ping, a dead socket is detected within ~10s and the
  /// store reconnects and refreshes history. IOWebSocketChannel because ping
  /// frames need dart:io — every Clippy target (macOS/Windows/Android) is
  /// dart:io; there is no web build.
  WebSocketRelayTransport(Uri url)
      : _channel = IOWebSocketChannel.connect(
          url,
          pingInterval: const Duration(seconds: 10),
        );

  @override
  Stream<String> get messages => _channel.stream.map((d) => d as String);

  @override
  void send(String message) => _channel.sink.add(message);

  @override
  Future<void> close() => _channel.sink.close();
}
