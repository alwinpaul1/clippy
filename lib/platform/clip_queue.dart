import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Drains texts the background AccessibilityService (ClipboardA11yService)
/// captured and wrote to filesDir/clip_queue. Consumed by the app on resume
/// and by the foreground service on its tick; the sync engine's dedup makes
/// double-drains harmless. No-op off Android.
abstract class ClipQueue {
  static Future<List<String>> drain() async {
    if (kIsWeb || !Platform.isAndroid) return const [];
    try {
      final base = await getApplicationSupportDirectory(); // == Context.filesDir
      final dir = Directory('${base.path}/clip_queue');
      if (!dir.existsSync()) return const [];
      final files = dir.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      final texts = <String>[];
      for (final f in files) {
        try {
          final t = await f.readAsString();
          if (t.isNotEmpty) texts.add(t);
        } catch (_) {}
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
