import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Drains texts the Clippy keyboard (ClippyImeService) queued while no Dart
/// isolate could take them instantly — one file per copied text under
/// filesDir/clip_queue (see the Kotlin side). Consumed by the foreground
/// service's tick and by the UI on resume; the sync engine's dedup rules make
/// double-drains harmless. No-op off Android.
abstract class ClipQueue {
  static Future<List<String>> drain() async {
    if (kIsWeb || !Platform.isAndroid) return const [];
    try {
      // getApplicationSupportDirectory == Context.getFilesDir on Android,
      // which is where the keyboard writes.
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/clip_queue');
      if (!dir.existsSync()) return const [];
      final files = dir.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path)); // timestamp names = order
      final texts = <String>[];
      for (final f in files) {
        try {
          final t = await f.readAsString();
          if (t.isNotEmpty) texts.add(t);
        } catch (_) {
          // Unreadable entry — drop it.
        }
        try {
          await f.delete();
        } catch (_) {}
      }
      return texts;
    } catch (_) {
      return const [];
    }
  }
}
