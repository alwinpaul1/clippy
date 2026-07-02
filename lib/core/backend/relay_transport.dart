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
  WebSocketRelayTransport(Uri url) : _channel = WebSocketChannel.connect(url);

  @override
  Stream<String> get messages => _channel.stream.map((d) => d as String);

  @override
  void send(String message) => _channel.sink.add(message);

  @override
  Future<void> close() => _channel.sink.close();
}
