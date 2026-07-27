import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// Clippy zero-knowledge relay.
///
/// Devices that scanned the same pairing QR share a 256-bit master key. From it
/// each derives an opaque `room` token (HMAC(masterKey, "…room…")) and the
/// content keys. This server only ever sees the room token and E2E-encrypted
/// payloads — never the master key, plaintext, or any identity. It is a dumb
/// encrypted-message router that also keeps the last N clips per room (durably,
/// see [ClipRepository]) so a reconnecting device catches up.
// MUST equal the clients' visible-history capacity (HistoryStore capacity in
// lib/core/history/history_store.dart): a deeper server history means clips
// that are invisible in every UI yet resurface after a delete-all-visible.
// Depth is a UI concern only — delivery proof is the explicit 'ack' frame,
// resends are idempotent (move-to-top), and resends of deleted content are
// answered with 'reject' via tombstones, so nothing correctness-critical
// rides on this value. (The 1.0.25-era snapshot-as-proof clients that once
// required 60 here are gone — the fleet is entirely on the ack protocol.)
const int maxHistory = 25;
// Images sync at original quality with no downscaling, so this must fit a
// full-screen Retina PNG raw: ~36MB image × ~1.78 (base64 → encrypted →
// base64) ≈ 64M chars. Not const: tests shrink it so the oversized-clip
// fixture doesn't materialize hundreds of MB (same reason maxHistory-scaled
// fixtures exist).
int maxCiphertextChars = 64000000;
const int maxRoomTokenChars = 512;

/// Per-room clip history storage. A clip whose hash already exists anywhere
/// in the room's history moves to the top instead of duplicating (this makes
/// client resends idempotent — the ack protocol depends on it); the list is
/// capped at [maxHistory].
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

  /// Make any pending writes durable. No-op for non-persistent stores; the
  /// server calls this on SIGTERM/SIGINT so a deploy never loses state.
  Future<void> flush();
}

class InMemoryClipRepository implements ClipRepository {
  final Map<String, List<Map<String, dynamic>>> rooms = {};

  @override
  List<Map<String, dynamic>> recent(String room) =>
      List.of(rooms[room] ?? const []);

  @override
  void add(String room, Map<String, dynamic> clip) {
    final list = rooms.putIfAbsent(room, () => []);
    // Same content anywhere in history moves to the top instead of appending a
    // duplicate entry. This makes a client's resend of an unacked clip (the
    // ack was lost with the socket) idempotent, and gives a deliberate re-copy
    // its expected move-to-top.
    list.removeWhere((c) => c['hash'] == clip['hash']);
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

  @override
  Future<void> flush() async {} // nothing pending — memory is the store
}

/// Persists history to a JSON file (atomic temp-write + rename) so it survives
/// restarts. Falls back to serving from memory if the path is unwritable, so
/// the relay never crashes on a missing/unmounted volume.
class FileClipRepository extends InMemoryClipRepository {
  final String path;

  /// Coalescing window for ADD-triggered disk writes (clips arrive in
  /// bursts). Destructive edits skip it — see [remove]/[clear]/[delete] —
  /// and [flush] force-completes it (the SIGTERM path: Railway kills the
  /// container on every deploy, and an add inside the window was already
  /// acked to its sender). Only a hard crash can still lose the window.
  final Duration persistDelay;
  Timer? _persistTimer;
  Future<void>? _inFlight;
  bool _dirty = false; // mutated while a write was in flight → write again

  FileClipRepository(this.path,
      {this.persistDelay = const Duration(seconds: 2)}) {
    _load();
  }

  void _schedulePersist() {
    // A mutation landing WHILE a write is in flight must mark the snapshot
    // dirty, not just arm the timer: flush()/SIGTERM kills the timer, and
    // without _dirty the in-flight loop would exit believing it wrote
    // everything — losing a clip the sender was already acked for.
    if (_inFlight != null) {
      _dirty = true;
      return;
    }
    _persistTimer ??= Timer(persistDelay, () {
      _persistTimer = null;
      _persist();
    });
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
      // Synchronous on purpose: nothing is serving traffic yet at load time,
      // and callers may read the swept file right after construction.
      if (rooms.length != before) _write(path, rooms);
    } catch (_) {
      // Corrupt/absent file → start empty.
    }
  }

  /// Encode + write happen OFF this isolate: with image ciphertexts retained,
  /// jsonEncoding every room synchronously can block the single relay isolate
  /// for seconds, stalling every room's WebSocket frames. [Isolate.run]'s
  /// message copy shares the (immutable) ciphertext strings, so the spawn is
  /// cheap and the worker encodes a consistent snapshot while this isolate
  /// keeps serving. Never runs concurrently with itself: a mutation during a
  /// write marks [_dirty] and the loop writes once more with the newer state.
  Future<void> _persist() {
    final running = _inFlight;
    if (running != null) {
      _dirty = true;
      return running;
    }
    return _inFlight = _persistLoop();
  }

  Future<void> _persistLoop() async {
    try {
      do {
        _dirty = false;
        final p = path;
        final snapshot = rooms;
        try {
          await Isolate.run(() => _write(p, snapshot));
        } catch (_) {
          // Worker spawn failed (resource pressure). _write itself never
          // throws, so this is the ONLY failure path — degrade to a blocking
          // main-isolate write rather than letting the rejection escape:
          // callers use unawaited(flush()) and an unhandled error here would
          // take down the whole relay (and skip the SIGTERM exit).
          _write(p, snapshot);
        }
      } while (_dirty);
    } finally {
      _inFlight = null;
    }
  }

  static void _write(
      String path, Map<String, List<Map<String, dynamic>>> rooms) {
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
  Future<void> flush() {
    _persistTimer?.cancel();
    _persistTimer = null;
    return _persist();
  }

  @override
  void add(String room, Map<String, dynamic> clip) {
    super.add(room, clip);
    _schedulePersist();
  }

  @override
  List<String> remove(String room, Set<String> hashes) {
    final removed = super.remove(room, hashes);
    // Destructive edits are rare and the UI already told the user "gone for
    // good" — skip the coalescing window so a crash or redeploy inside it
    // can't resurrect the clip in every device's next snapshot.
    if (removed.isNotEmpty) unawaited(flush());
    return removed;
  }

  @override
  void clear(String room) {
    super.clear(room);
    unawaited(flush()); // same resurrection risk as remove()
  }

  @override
  void delete(String room) {
    super.delete(room);
    unawaited(flush());
  }
}

/// Live WebSocket connections per room (not persisted).
final Map<String, Set<WebSocket>> roomClients = {};

/// Recently deleted content hashes per room (hash → deletedAt ISO), so a
/// client RESEND of a clip that another device deleted while the sender was
/// offline is answered with 'reject' (sender stops resending; nothing
/// resurrects) — while a FRESH copy of the same content (no resend flag) is a
/// new user intent that revives it and clears the tombstone. Time cannot make
/// this distinction; the flag can. In-memory and bounded: a relay restart
/// forgets tombstones, so the resurrection residual is only resend + deletion
/// + redeploy coinciding within one offline window.
final Map<String, Map<String, String>> roomTombstones = {};
const int _maxTombstonesPerRoom = 200;

void _tombstone(String room, Iterable<String> hashes) {
  final tomb = roomTombstones.putIfAbsent(room, () => {});
  final now = nowIso();
  for (final h in hashes) {
    tomb.remove(h); // re-insert as newest
    tomb[h] = now;
  }
  while (tomb.length > _maxTombstonesPerRoom) {
    tomb.remove(tomb.keys.first);
  }
}

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

/// Send [msg] to one socket if it is still open (ack/reject to the uploader).
void _sendTo(WebSocket ws, Map<String, dynamic> msg) {
  if (ws.readyState == WebSocket.open) ws.add(jsonEncode(msg));
}

/// Parse an optional client 'before' watermark, clamped to server-now: a
/// destructive edit applies only to content at-or-before the moment the user
/// acted, however late the frame replays — clips added afterwards survive.
/// Clamping caps a forward-skewed device clock at "everything current".
/// Null (absent/unparseable) means the caller should use legacy semantics.
DateTime? _watermark(dynamic before) {
  if (before is! String) return null;
  final t = DateTime.tryParse(before);
  if (t == null) return null;
  final now = DateTime.parse(nowIso());
  return t.isAfter(now) ? now : t;
}

/// Hashes in [room]'s history whose server timestamp is at-or-before [cutoff].
Set<String> _hashesBefore(String room, DateTime cutoff) => {
      for (final c in repository.recent(room))
        if (c['hash'] is String &&
            c['timestamp'] is String &&
            !DateTime.parse(c['timestamp'] as String).isAfter(cutoff))
          c['hash'] as String,
    };

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
      if (repository.recent(r).isEmpty) {
        repository.delete(r);
        roomTombstones.remove(r); // a reclaimed code starts with a clean slate
      }
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
          _sendTo(ws, {'type': 'history', 'clips': repository.recent(token)});
          break;

        case 'clip':
          final r = room;
          if (r == null) return; // must join first
          final clip = msg['clip'];
          if (clip is! Map) return;
          final ciphertext = clip['ciphertext'];
          final hash = clip['hash'];
          if (ciphertext is! String ||
              ciphertext.length > maxCiphertextChars) {
            // Tell the sender this clip can NEVER succeed — a silent drop
            // would leave it queued client-side and re-uploaded forever.
            if (hash is String) {
              _sendTo(ws, {'type': 'reject', 'hash': hash});
            }
            return;
          }
          // A hashless clip can never be acked, deduped, or deleted — and a
          // stored null hash would make the move-to-top removeWhere below
          // match (null == null) every other hashless clip and purge them.
          if (hash is! String || hash.isEmpty) return;
          // A RESEND of content another device deleted while the sender was
          // offline must not resurrect it: answer 'reject' so the sender
          // stops retrying. A fresh copy (no resend flag) is new user intent
          // — it revives the content and clears the tombstone below.
          if (msg['resend'] == true &&
              (roomTombstones[r]?.containsKey(hash) ?? false)) {
            _sendTo(ws, {'type': 'reject', 'hash': hash});
            return;
          }
          roomTombstones[r]?.remove(hash);
          // Server stamps the authoritative timestamp; ordering never trusts a
          // device clock.
          final stored = <String, dynamic>{
            'ciphertext': ciphertext,
            'iv': clip['iv'],
            'hash': hash,
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
          _broadcast(r, {'type': 'clip', 'clip': stored});
          // Explicit delivery proof to the uploader: the client holds every
          // clip as unacked-and-resendable until this arrives. (The broadcast
          // echo above doubles as a hint, but the ack is the contract.)
          _sendTo(ws, {'type': 'ack', 'hash': hash});
          break;

        case 'delete':
          final r = room;
          if (r == null) return;
          final raw = msg['hashes'];
          if (raw is! List) return;
          var hashes = raw.whereType<String>().toSet();
          if (hashes.isEmpty) return;
          // Watermark: a delete replayed long after the user acted must not
          // kill a NEWER copy of the same content (a hash names content, not
          // an instance — another device may have deliberately re-copied it
          // since). Scope the delete to clips stamped at-or-before the action.
          final delCutoff = _watermark(msg['before']);
          if (delCutoff != null) {
            hashes = hashes.intersection(_hashesBefore(r, delCutoff));
            if (hashes.isEmpty) return;
          }
          final removed = repository.remove(r, hashes);
          if (removed.isEmpty) return;
          _tombstone(r, removed); // resends of these get 'reject', not revival
          _broadcast(r, {'type': 'deleted', 'hashes': removed});
          break;

        case 'clear':
          final r = room;
          if (r == null) return;
          // Watermarked clear ("everything at-or-before the moment the user
          // acted"): applies correctly however late the frame replays — clips
          // other devices added AFTER the user's intent survive, clips the
          // user never saw but that predate the intent are still cleared.
          final clearCutoff = _watermark(msg['before']);
          if (clearCutoff != null) {
            final doomed = _hashesBefore(r, clearCutoff);
            final removed = repository.remove(r, doomed);
            if (removed.isEmpty) return;
            _tombstone(r, removed);
            _broadcast(r, {'type': 'deleted', 'hashes': removed});
            return;
          }
          // Legacy unscoped clear (pre-1.0.28 clients).
          _tombstone(
              r, repository.recent(r).map((c) => c['hash']).whereType<String>());
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
