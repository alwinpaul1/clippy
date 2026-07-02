import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Clippy zero-knowledge relay.
///
/// Devices that scanned the same pairing QR share a 256-bit master key. From it
/// each derives an opaque `room` token (HMAC(masterKey, "…room…")) and the
/// content keys. This server only ever sees the room token and E2E-encrypted
/// payloads — never the master key, never plaintext, never any identity. It is
/// a dumb encrypted-message router that also keeps the last N clips per room so
/// a reconnecting device catches up.
const int maxHistory = 25;
const int maxCiphertextChars = 200000; // ~150KB plaintext, base64-encoded
const int maxRoomTokenChars = 512;

class Room {
  final Set<WebSocket> clients = {};
  final List<Map<String, dynamic>> history = [];

  void remember(Map<String, dynamic> clip) {
    if (history.isNotEmpty && history.last['hash'] == clip['hash']) {
      return; // collapse consecutive duplicates
    }
    history.add(clip);
    if (history.length > maxHistory) {
      history.removeRange(0, history.length - maxHistory);
    }
  }
}

/// In-memory room table. History lives as long as the relay process runs;
/// durable per-room persistence (SQLite on a Railway volume) is a follow-up.
final Map<String, Room> rooms = {};

/// Injectable clock so tests are deterministic; real runtime uses wall time.
String Function() nowIso = () => DateTime.now().toUtc().toIso8601String();

Future<HttpServer> startServer(int port) async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  server.listen(_handleRequest);
  return server;
}

Future<void> _handleRequest(HttpRequest req) async {
  // WebSocket clients connect to "/", so the upgrade check must come first —
  // otherwise a WS handshake to "/" would be answered as a health check.
  if (WebSocketTransformer.isUpgradeRequest(req)) {
    final ws = await WebSocketTransformer.upgrade(req);
    _handleSocket(ws);
    return;
  }
  if (req.uri.path == '/health' || req.uri.path == '/') {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.text
      ..write('ok');
    await req.response.close();
    return;
  }
  req.response.statusCode = HttpStatus.notFound;
  await req.response.close();
}

void _handleSocket(WebSocket ws) {
  Room? room;

  ws.listen(
    (dynamic raw) {
      Map<String, dynamic> msg;
      try {
        msg = jsonDecode(raw as String) as Map<String, dynamic>;
      } catch (_) {
        return; // ignore malformed frames
      }

      switch (msg['type']) {
        case 'join':
          if (room != null) return; // already joined
          final token = msg['room'];
          if (token is! String ||
              token.isEmpty ||
              token.length > maxRoomTokenChars) {
            ws.close(WebSocketStatus.policyViolation, 'bad room');
            return;
          }
          room = rooms.putIfAbsent(token, Room.new)..clients.add(ws);
          ws.add(jsonEncode({'type': 'history', 'clips': room!.history}));
          break;

        case 'clip':
          final r = room;
          if (r == null) return; // must join first
          final clip = msg['clip'];
          if (clip is! Map) return;
          final ciphertext = clip['ciphertext'];
          if (ciphertext is! String ||
              ciphertext.length > maxCiphertextChars) {
            return;
          }
          // Server stamps the authoritative timestamp; ordering never trusts
          // a device clock.
          final stored = <String, dynamic>{
            'ciphertext': ciphertext,
            'iv': clip['iv'],
            'hash': clip['hash'],
            'source': clip['source'],
            'timestamp': nowIso(),
          };
          r.remember(stored);
          final out = jsonEncode({'type': 'clip', 'clip': stored});
          for (final peer in r.clients) {
            if (peer != ws && peer.readyState == WebSocket.open) {
              peer.add(out);
            }
          }
          break;
      }
    },
    onDone: () => room?.clients.remove(ws),
    onError: (_) => room?.clients.remove(ws),
    cancelOnError: true,
  );
}
