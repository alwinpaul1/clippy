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
// Images sync at original quality with no downscaling, so this must fit a
// full-screen Retina PNG raw: ~36MB image × ~1.78 (base64 → encrypted →
// base64) ≈ 64M chars.
const int maxCiphertextChars = 64000000;
const int maxRoomTokenChars = 512;

/// Per-room clip history storage. Consecutive duplicate hashes collapse and the
/// list is capped at [maxHistory].
abstract class ClipRepository {
  List<Map<String, dynamic>> recent(String room);
  void add(String room, Map<String, dynamic> clip);

  /// Remove clips whose hash is in [hashes]. Returns the hashes actually
  /// removed (so the broadcast reflects real deletions).
  List<String> remove(String room, Set<String> hashes);

  /// Drop the whole room's history.
  void clear(String room);

  /// Remove the room entirely (its key too, not just its clips). Used to
  /// reclaim a pairing code that holds no clips and has no connected devices —
  /// an empty room has no data to lose and is recreated on the next clip.
  void delete(String room);
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

  @override
  List<String> remove(String room, Set<String> hashes) {
    final list = rooms[room];
    if (list == null) return const [];
    final removed = <String>[];
    list.removeWhere((c) {
      final h = c['hash'];
      if (h is String && hashes.contains(h)) {
        removed.add(h);
        return true;
      }
      return false;
    });
    return removed;
  }

  @override
  void clear(String room) {
    rooms[room]?.clear();
  }

  @override
  void delete(String room) {
    rooms.remove(room);
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
      // Reclaim empty pairing codes left in the file (e.g. a room whose history
      // was cleared while no device was connected, so the disconnect-time sweep
      // never ran). An empty room has no data, so this loses nothing.
      final before = rooms.length;
      rooms.removeWhere((_, clips) => clips.isEmpty);
      if (rooms.length != before) _persist();
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

  @override
  List<String> remove(String room, Set<String> hashes) {
    final removed = super.remove(room, hashes);
    if (removed.isNotEmpty) _persist();
    return removed;
  }

  @override
  void clear(String room) {
    super.clear(room);
    _persist();
  }

  @override
  void delete(String room) {
    super.delete(room);
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
  if (req.uri.path == '/health') {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.text
      ..write('ok');
    await req.response.close();
    return;
  }
  if (req.uri.path == '/' || req.uri.path == '/index.html') {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(_downloadPage());
    await req.response.close();
    return;
  }
  if (req.uri.path.startsWith('/download/')) {
    await _serveDownload(req);
    return;
  }
  if (req.uri.path == '/version.json') {
    await _serveVersion(req);
    return;
  }
  req.response.statusCode = HttpStatus.notFound;
  await req.response.close();
}

// The in-app updater's manifest (latest version + changelog), generated by CI
// into web/downloads/version.json alongside the release artifacts.
Future<void> _serveVersion(HttpRequest req) async {
  for (final dir in [
    'web/downloads',
    '/app/web/downloads',
    '${File(Platform.resolvedExecutable).parent.parent.path}/web/downloads',
  ]) {
    final file = File('$dir/version.json');
    if (file.existsSync()) {
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'json')
        ..add(await file.readAsBytes());
      await req.response.close();
      return;
    }
  }
  req.response.statusCode = HttpStatus.notFound;
  await req.response.close();
}

// The app builds available for download (allow-listed — no path traversal).
const _downloads = {
  'Clippy-macOS.dmg': 'application/x-apple-diskimage',
  'Clippy-macOS.zip': 'application/zip', // raw .app for in-app self-update
  'Clippy-Setup.exe': 'application/octet-stream',
  'Clippy-Android.apk': 'application/vnd.android.package-archive',
};

Future<void> _serveDownload(HttpRequest req) async {
  final segments = req.uri.pathSegments; // ['download', '<name>']
  final name = segments.length == 2 ? segments[1] : '';
  final mime = _downloads[name];
  if (mime != null) {
    for (final dir in [
      'web/downloads',
      '/app/web/downloads',
      '${File(Platform.resolvedExecutable).parent.parent.path}/web/downloads',
    ]) {
      final file = File('$dir/$name');
      if (file.existsSync()) {
        final parts = mime.split('/');
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType(parts[0], parts[1])
          ..headers.add('Content-Disposition', 'attachment; filename="$name"');
        await req.response.addStream(file.openRead());
        await req.response.close();
        return;
      }
    }
  }
  req.response.statusCode = HttpStatus.notFound;
  await req.response.close();
}

String? _downloadPageCache;

/// The public download page (served at "/"). Loaded once from disk; the
/// Dockerfile copies web/ next to the binary.
String _downloadPage() {
  if (_downloadPageCache != null) return _downloadPageCache!;
  final candidates = <String>[
    'web/index.html',
    '/app/web/index.html',
    '${File(Platform.resolvedExecutable).parent.parent.path}/web/index.html',
  ];
  for (final path in candidates) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        return _downloadPageCache = file.readAsStringSync();
      }
    } catch (_) {
      // Try the next candidate.
    }
  }
  return _downloadPageCache =
      '<!doctype html><title>Clippy</title>'
      '<body style="font-family:system-ui;padding:40px">'
      '<h1>Clippy relay</h1><p>The download page is unavailable.</p>';
}

/// Send [msg] to every open socket in [room].
void _broadcast(String room, Map<String, dynamic> msg) {
  final out = jsonEncode(msg);
  for (final peer in roomClients[room] ?? const <WebSocket>{}) {
    if (peer.readyState == WebSocket.open) peer.add(out);
  }
}

void _handleSocket(WebSocket ws) {
  String? room;

  void leave() {
    final r = room;
    if (r == null) return;
    final clients = roomClients[r]?..remove(ws);
    if (clients == null || clients.isEmpty) {
      roomClients.remove(r); // no live sockets left — drop the empty set
      // Last device for this pairing code just left: if it holds no clips,
      // reclaim it. A room that still has clips is kept — its devices are only
      // offline, not gone, and deleting it would lose their history.
      if (repository.recent(r).isEmpty) repository.delete(r);
    }
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
            'device': clip['device'],
            'kind': clip['kind'],
            'mime': clip['mime'],
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

        case 'delete':
          final r = room;
          if (r == null) return;
          final raw = msg['hashes'];
          if (raw is! List) return;
          final hashes = raw.whereType<String>().toSet();
          if (hashes.isEmpty) return;
          final removed = repository.remove(r, hashes);
          if (removed.isEmpty) return;
          _broadcast(r, {'type': 'deleted', 'hashes': removed});
          break;

        case 'clear':
          final r = room;
          if (r == null) return;
          repository.clear(r);
          _broadcast(r, {'type': 'cleared'});
          break;
      }
    },
    onDone: leave,
    onError: (_) => leave(),
    cancelOnError: true,
  );
}
