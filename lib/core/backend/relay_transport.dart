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

  /// [pingInterval] keeps sync from going stale on a HALF-OPEN socket (Wi-Fi
  /// hop, NAT idle-timeout, wake-from-sleep): such a socket still looks
  /// connected but silently delivers nothing, so a clip / delete / clear-all
  /// broadcast never arrives until TCP times out — minutes of stale history.
  /// With the ping, dart:io detects the dead socket and fires onDone, and the
  /// store reconnects + refreshes history. Note dart:io only requires a pong
  /// before the NEXT ping, so worst-case detection is up to ~2× the interval
  /// (~20s here), not ~10s. IOWebSocketChannel because ping frames need
  /// dart:io — every Clippy target (macOS/Windows/Android) is dart:io; there
  /// is no web build.
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
