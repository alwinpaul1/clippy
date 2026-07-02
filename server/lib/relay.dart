import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Clippy zero-knowledge relay.
///
/// Devices that scanned the same pairing QR share a 256-bit master key. From it
/// each derives an opaque `room` token (HMAC(masterKey, "…room…")) and the
/// content keys. This server only ever sees the room token and E2E-encrypted
/// payloads — never the master key, plaintext, or any identity. It is a dumb
/// encrypted-message router that also keeps the last N clips per room (durably,
/// see [ClipRepository]) so a reconnecting device catches up.
const int maxHistory = 25;
const int maxCiphertextChars = 200000; // ~150KB plaintext, base64-encoded
const int maxRoomTokenChars = 512;

/// Per-room clip history storage. Consecutive duplicate hashes collapse and the
/// list is capped at [maxHistory].
abstract class ClipRepository {
  List<Map<String, dynamic>> recent(String room);
  void add(String room, Map<String, dynamic> clip);
}

class InMemoryClipRepository implements ClipRepository {
  final Map<String, List<Map<String, dynamic>>> rooms = {};

  @override
  List<Map<String, dynamic>> recent(String room) =>
      List.of(rooms[room] ?? const []);

  @override
  void add(String room, Map<String, dynamic> clip) {
    final list = rooms.putIfAbsent(room, () => []);
    if (list.isNotEmpty && list.last['hash'] == clip['hash']) return;
    list.add(clip);
    if (list.length > maxHistory) {
      list.removeRange(0, list.length - maxHistory);
    }
  }
}

/// Persists history to a JSON file (atomic temp-write + rename) so it survives
/// restarts. Falls back to serving from memory if the path is unwritable, so
/// the relay never crashes on a missing/unmounted volume.
class FileClipRepository extends InMemoryClipRepository {
  final String path;

  FileClipRepository(this.path) {
    _load();
  }

  void _load() {
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      data.forEach((room, clips) {
        rooms[room] = (clips as List)
            .map((c) => (c as Map).cast<String, dynamic>())
            .toList();
      });
    } catch (_) {
      // Corrupt/absent file → start empty.
    }
  }

  void _persist() {
    try {
      final dir = File(path).parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(jsonEncode(rooms));
      tmp.renameSync(path);
    } catch (_) {
      // Keep serving from memory if the volume is unavailable.
    }
  }

  @override
  void add(String room, Map<String, dynamic> clip) {
    super.add(room, clip);
    _persist();
  }
}

/// Live WebSocket connections per room (not persisted).
final Map<String, Set<WebSocket>> roomClients = {};

/// The active history store. Tests reset this to a fresh in-memory instance.
ClipRepository repository = InMemoryClipRepository();

/// Injectable clock so tests are deterministic; real runtime uses wall time.
String Function() nowIso = () => DateTime.now().toUtc().toIso8601String();

Future<HttpServer> startServer(int port, {ClipRepository? repo}) async {
  if (repo != null) repository = repo;
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
  String? room;

  void leave() {
    if (room != null) roomClients[room]?.remove(ws);
  }

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
          room = token;
          roomClients.putIfAbsent(token, () => {}).add(ws);
          ws.add(jsonEncode({'type': 'history', 'clips': repository.recent(token)}));
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
          // Server stamps the authoritative timestamp; ordering never trusts a
          // device clock.
          final stored = <String, dynamic>{
            'ciphertext': ciphertext,
            'iv': clip['iv'],
            'hash': clip['hash'],
            'source': clip['source'],
            'timestamp': nowIso(),
          };
          repository.add(r, stored);
          // Broadcast to ALL room members including the sender, so every device
          // sees uniform server-stamped clips. A device ignores its own clips
          // for the clipboard-apply decision (SyncEngine source check) but still
          // shows them in history.
          final out = jsonEncode({'type': 'clip', 'clip': stored});
          for (final peer in roomClients[r] ?? const <WebSocket>{}) {
            if (peer.readyState == WebSocket.open) {
              peer.add(out);
            }
          }
          break;
      }
    },
    onDone: leave,
    onError: (_) => leave(),
    cancelOnError: true,
  );
}
