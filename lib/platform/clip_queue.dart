import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One captured clipboard item drained from the queue: text or an image.
/// [name] is the source file's basename — requeue() writes an undelivered
/// item back under its ORIGINAL name, preserving capture order (a fresh
/// timestamp would re-order old content after newer captures) and making the
/// write idempotent across the two draining isolates.
class ClipQueueItem {
  final String? text;
  final Uint8List? imageBytes;
  final String? mime;
  final String? name;
  const ClipQueueItem.text(String this.text, {this.name})
      : imageBytes = null,
        mime = null;
  const ClipQueueItem.image(Uint8List this.imageBytes, String this.mime,
      {this.name})
      : text = null;
  bool get isImage => imageBytes != null;
}

/// Drains clips the background native code (ClipboardA11yService: focus-trick
/// text + a MediaStore observer for screenshots) captured to filesDir/clip_queue.
/// Text lands as `<ts>.txt`, images as `<ts>.png|jpg|webp|gif`. Consumed by the
/// app on resume and by the foreground service; the sync engine's dedup makes
/// double-drains harmless. No-op off Android.
abstract class ClipQueue {
  static Directory? _cachedDir;

  /// Test hook: overrides the (Android-only) queue directory so the queue
  /// logic is exercisable in host unit tests.
  @visibleForTesting
  static Directory? debugDir;

  static const _imageMimes = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
  };

  static Future<Directory?> _dir() async {
    if (debugDir != null) return debugDir;
    if (kIsWeb || !Platform.isAndroid) return null;
    if (_cachedDir != null) return _cachedDir;
    try {
      final base = await getApplicationSupportDirectory(); // == Context.filesDir
      _cachedDir = Directory('${base.path}/clip_queue');
      return _cachedDir;
    } catch (_) {
      return null;
    }
  }

  /// How much a single drain may hold in memory at once. The queue's own bound
  /// is 200MB of DISK, and every drained item is materialized as bytes in a
  /// list — an hours-long backlog (the service died; captures kept landing)
  /// would otherwise be read in one go and OOM the app at the worst possible
  /// moment: launch. Whatever doesn't fit stays on disk, oldest-first, and the
  /// next drain takes the next batch.
  @visibleForTesting
  static int maxDrainBytes = 24 << 20;
  @visibleForTesting
  static int maxDrainFiles = 30;

  static Future<List<ClipQueueItem>> drain() async {
    final dir = await _dir();
    if (dir == null) return const [];
    try {
      if (!dir.existsSync()) return const [];
      final files = dir.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (files.isEmpty) return const [];
      final items = <ClipQueueItem>[];
      var bytes = 0;
      for (final f in files) {
        final ext = f.path.split('.').last.toLowerCase();
        // Images are staged as `<name>.part` then renamed in, so a `.part`
        // seen mid-rename is incomplete — the next drain gets it. But a rename
        // that never completed (writer killed, rename failed) would otherwise
        // orphan the file forever — reap it once it's clearly stale.
        if (ext == 'part') {
          _reapIfStale(f);
          continue;
        }
        // Batch cap: stop BEFORE consuming the file, so it stays on disk (the
        // only crash-proof copy) for the next pass. Never cap at zero items —
        // one clip larger than the budget must still make progress.
        if (items.isNotEmpty &&
            (items.length >= maxDrainFiles || bytes >= maxDrainBytes)) {
          break;
        }
        final mime = _imageMimes[ext];
        final item =
            mime != null ? await _drainImage(f, mime) : await _drainText(f);
        if (item != null) {
          items.add(item);
          bytes += item.imageBytes?.length ?? item.text?.length ?? 0;
        }
      }
      return items;
    } catch (_) {
      return const [];
    }
  }

  static Future<ClipQueueItem?> _drainText(File f) async {
    String t;
    try {
      t = await f.readAsString();
    } catch (_) {
      return null; // mid-write race — the next drain gets it
    }
    if (t.isEmpty) {
      _reapIfStale(f);
      return null;
    }
    try {
      await f.delete();
    } catch (_) {}
    return ClipQueueItem.text(t, name: f.uri.pathSegments.last);
  }

  static Future<ClipQueueItem?> _drainImage(File f, String mime) async {
    Uint8List bytes;
    try {
      bytes = await f.readAsBytes();
    } catch (_) {
      return null;
    }
    if (bytes.isEmpty) {
      _reapIfStale(f);
      return null;
    }
    try {
      await f.delete();
    } catch (_) {}
    return ClipQueueItem.image(bytes, mime, name: f.uri.pathSegments.last);
  }

  /// Whether [f]'s last modification is older than [age]. Treats a
  /// stat failure (file vanished under a concurrent delete) as "not older" so
  /// callers simply skip it.
  static bool _olderThan(File f, Duration age) {
    try {
      return DateTime.now().difference(f.statSync().modified) > age;
    } catch (_) {
      return false;
    }
  }

  /// A file that stays empty (writer killed mid-write) is re-listed on every
  /// drain forever — reap it after a grace window.
  static void _reapIfStale(File f) {
    try {
      if (_olderThan(f, const Duration(seconds: 30))) f.deleteSync();
    } catch (_) {}
  }

  /// Put a drained item BACK on disk under its ORIGINAL filename. drain()
  /// consumes the file before the send happens, so if the relay link dies
  /// mid-drain the disk copy — the only one that survives a process kill —
  /// would be gone. Both types go through .part+rename staging so a
  /// concurrent drain (or the inotify watcher this write triggers) never
  /// reads a half-written file. Reusing the original name preserves capture
  /// order in the drain's path sort and makes concurrent requeues of the
  /// same item (both isolates drained the same file) collide harmlessly on
  /// identical content. Best-effort: items the drain loop never reached have
  /// NO other copy, so a failed write here is a genuine (rare) loss.
  static Future<void> requeue(ClipQueueItem item) async {
    final name = item.name;
    if (name == null || name.contains('/')) return; // only drain-produced items
    final dir = await _dir();
    if (dir == null) return;
    try {
      dir.createSync(recursive: true);
      final part = File('${dir.path}/$name.part');
      if (item.isImage) {
        await part.writeAsBytes(item.imageBytes!);
      } else {
        await part.writeAsString(item.text!);
      }
      try {
        part.renameSync('${dir.path}/$name');
      } catch (_) {
        part.deleteSync(); // don't leave an orphan blocking the reaper
      }
    } catch (_) {
      // Disk full / dir gone — nothing more we can do without the file.
    }
  }

  /// Requeue every item, preserving order. Used when a drain must abort
  /// mid-way (link died, controller disposed) with items already consumed.
  static Future<void> requeueAll(Iterable<ClipQueueItem> items) async {
    for (final item in items) {
      await requeue(item);
    }
  }

  // The queue only grows while the relay is unreachable (drains are gated on
  // a confirmed link), and nothing else bounds it — a device that stays
  // paired-but-unconnected would accumulate captures (multi-MB images
  // included) without limit. Mutable only so tests can shrink the fixture.
  @visibleForTesting
  static int maxQueueFiles = 200;
  @visibleForTesting
  static int maxQueueBytes = 200 << 20;

  /// How long a queue file must sit untouched before the bound may prune it.
  /// This — a per-file property, not shared lock state — is the cross-isolate
  /// safety: anything a drain just requeued (or a writer just staged) carries
  /// a fresh mtime and is structurally unprunable, with no heartbeat for a
  /// concurrent drain to delete out from under the other isolate. An OLD
  /// over-bound file can still be pruned while the other isolate's drain is
  /// mid-flight — but pruning it is exactly the bound's stated policy.
  static const _pruneMinAge = Duration(minutes: 1);

  /// Drop the oldest queue files while over the count/byte bound. `.part`
  /// staging files are exempt from the bound (they are mid-write), but stale
  /// ones are reaped here too: while offline — the only time this runs —
  /// drain() never runs, so its reaper can't.
  static Future<void> enforceBound() async {
    final dir = await _dir();
    if (dir == null) return;
    try {
      if (!dir.existsSync()) return;
      // The bound is judged against EVERYTHING on disk (that's the real
      // usage), but only files past the age gate are eligible for deletion —
      // fresh writes protect themselves by mtime.
      var count = 0;
      var total = 0;
      final prunable = <(File, int)>[];
      for (final f in dir.listSync().whereType<File>()) {
        if (f.path.endsWith('.part')) {
          _reapIfStale(f);
          continue;
        }
        int size;
        try {
          size = f.statSync().size;
        } catch (_) {
          continue; // vanished between list and stat (concurrent delete)
        }
        count++;
        total += size;
        if (_olderThan(f, _pruneMinAge)) prunable.add((f, size));
      }
      prunable.sort((a, b) => a.$1.path.compareTo(b.$1.path)); // oldest first
      for (final (f, size) in prunable) {
        if (count <= maxQueueFiles && total <= maxQueueBytes) break;
        try {
          f.deleteSync();
        } catch (_) {
          // Failed with the file still present: NOT freed — counting it
          // would end the loop with the disk still over its bound. A file
          // that vanished concurrently is genuinely gone and still counts.
          var stillThere = true;
          try {
            stillThere = f.existsSync();
          } catch (_) {}
          if (stillThere) continue;
        }
        count--;
        total -= size;
      }
    } catch (_) {}
  }

  /// Instant sync: fires the moment native code writes a captured clip (inotify
  /// via Directory.watch). This is on filesDir (app-private ext4), where
  /// inotify is reliable — unlike external storage's FUSE mount. Returns null
  /// off Android; callers keep a slow poll as a fallback either way.
  static Future<Stream<void>?> watch() async {
    final dir = await _dir();
    if (dir == null) return null;
    try {
      dir.createSync(recursive: true); // must exist before watching
      // All events: text is a create/modify, images are renamed in (a move) —
      // drain is idempotent, so extra triggers are cheap.
      return dir.watch();
    } catch (_) {
      return null;
    }
  }
}
