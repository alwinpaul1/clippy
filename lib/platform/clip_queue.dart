import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Drains texts the background AccessibilityService (ClipboardA11yService)
/// captured and wrote to filesDir/clip_queue. Consumed by the app on resume
/// and by the foreground service on its tick; the sync engine's dedup makes
/// double-drains harmless. No-op off Android.
abstract class ClipQueue {
  static Directory? _cachedDir;

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

  static Future<List<String>> drain() async {
    final dir = await _dir();
    if (dir == null) return const [];
    try {
      if (!dir.existsSync()) return const [];
      final files = dir.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      final texts = <String>[];
      for (final f in files) {
        String t;
        try {
          t = await f.readAsString();
        } catch (_) {
          continue; // mid-write race — the next drain gets it
        }
        if (t.isEmpty) continue; // created but not yet written
        texts.add(t);
        try {
          await f.delete();
        } catch (_) {}
      }
      return texts;
    } catch (_) {
      return const [];
    }
  }

  /// Instant sync: fires the moment the AccessibilityService writes a captured
  /// clip (inotify via Directory.watch — supported on Android). Returns null
  /// off Android or if watching isn't possible; callers keep a slow poll as
  /// fallback either way.
  static Future<Stream<void>?> watch() async {
    final dir = await _dir();
    if (dir == null) return null;
    try {
      dir.createSync(recursive: true); // must exist before watching
      return dir.watch(events: FileSystemEvent.create | FileSystemEvent.modify);
    } catch (_) {
      return null;
    }
  }
}
