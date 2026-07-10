import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One captured clipboard item drained from the queue: text or an image.
class ClipQueueItem {
  final String? text;
  final Uint8List? imageBytes;
  final String? mime;
  const ClipQueueItem.text(String this.text)
      : imageBytes = null,
        mime = null;
  const ClipQueueItem.image(Uint8List this.imageBytes, String this.mime)
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

  static const _imageMimes = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
  };

  static Future<Directory?> _dir() async {
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

  static Future<List<ClipQueueItem>> drain() async {
    final dir = await _dir();
    if (dir == null) return const [];
    try {
      if (!dir.existsSync()) return const [];
      final files = dir.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      final items = <ClipQueueItem>[];
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
        final mime = _imageMimes[ext];
        final item =
            mime != null ? await _drainImage(f, mime) : await _drainText(f);
        if (item != null) items.add(item);
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
    return ClipQueueItem.text(t);
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
    return ClipQueueItem.image(bytes, mime);
  }

  /// A file that stays empty (writer killed mid-write) is re-listed on every
  /// drain forever — reap it after a grace window.
  static void _reapIfStale(File f) {
    try {
      final age = DateTime.now().difference(f.statSync().modified);
      if (age > const Duration(seconds: 30)) f.deleteSync();
    } catch (_) {}
  }

  static const _extForMime = {
    'image/png': 'png',
    'image/jpeg': 'jpg',
    'image/webp': 'webp',
    'image/gif': 'gif',
  };

  /// Put a drained item BACK on disk. drain() consumes the file before the
  /// send happens, so if the relay link dies mid-drain the disk copy — the
  /// only one that survives a process kill — would be gone. Callers requeue
  /// the undelivered remainder instead. Images go through the same
  /// .part+rename staging the native writer uses, so a concurrent drain never
  /// reads a half-written file.
  static Future<void> requeue(ClipQueueItem item) async {
    final dir = await _dir();
    if (dir == null) return;
    try {
      dir.createSync(recursive: true);
      var ts = DateTime.now().millisecondsSinceEpoch;
      if (item.isImage) {
        final ext = _extForMime[item.mime] ?? 'png';
        var f = File('${dir.path}/$ts.$ext');
        while (f.existsSync()) {
          f = File('${dir.path}/${++ts}.$ext');
        }
        final part = File('${f.path}.part');
        await part.writeAsBytes(item.imageBytes!);
        try {
          part.renameSync(f.path);
        } catch (_) {
          part.deleteSync(); // don't leave an orphan blocking the reaper
        }
      } else {
        var f = File('${dir.path}/$ts.txt');
        while (f.existsSync()) {
          f = File('${dir.path}/${++ts}.txt');
        }
        await f.writeAsString(item.text!);
      }
    } catch (_) {
      // Best effort — the in-memory unacked buffer still holds the clip.
    }
  }

  // The queue only grows while the relay is unreachable (drains are gated on
  // a confirmed link), and nothing else bounds it — a device that stays
  // paired-but-unconnected would accumulate captures (multi-MB images
  // included) without limit.
  static const _maxQueueFiles = 200;
  static const _maxQueueBytes = 200 << 20;

  /// Drop the oldest queue files while over the count/byte bound. Cheap for
  /// the typical near-empty directory; called from the service's slow tick.
  static Future<void> enforceBound() async {
    final dir = await _dir();
    if (dir == null) return;
    try {
      if (!dir.existsSync()) return;
      final files = dir.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path)); // timestamp names → oldest first
      var total = 0;
      for (final f in files) {
        total += f.statSync().size;
      }
      var count = files.length;
      for (final f in files) {
        if (count <= _maxQueueFiles && total <= _maxQueueBytes) break;
        try {
          final size = f.statSync().size;
          f.deleteSync();
          count--;
          total -= size;
        } catch (_) {}
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
