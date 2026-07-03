import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Watches macOS's screenshot save folder (⇧⌘3/4 write files there — they
/// never touch the clipboard, so the clipboard watcher can't see them) and
/// hands each new screenshot's bytes to [onImage]. No-op off macOS.
///
/// The folder and filename prefix come from the user's `com.apple.screencapture`
/// defaults (falling back to ~/Desktop and "Screenshot"), so plain images the
/// user saves to the same folder are ignored.
class MacScreenshotWatcher {
  MacScreenshotWatcher(this.onImage);

  final void Function(Uint8List bytes, String mime) onImage;
  StreamSubscription<FileSystemEvent>? _sub;
  final Set<String> _handled = {};

  Future<void> start() async {
    if (kIsWeb || !Platform.isMacOS) return;
    final dir = Directory(await _readDefault('location') ?? _desktop());
    if (!dir.existsSync()) return;
    final prefix = await _readDefault('name') ?? 'Screenshot';
    _sub = dir
        .watch(events: FileSystemEvent.create | FileSystemEvent.move)
        .listen((event) {
      final path = event is FileSystemMoveEvent
          ? (event.destination ?? event.path)
          : event.path;
      _maybeEmit(path, prefix);
    });
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _maybeEmit(String path, String prefix) async {
    final name = path.split('/').last;
    if (name.startsWith('.')) return; // temp/hidden files during capture
    if (!name.startsWith(prefix)) return;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const mimes = {'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg'};
    final mime = mimes[ext];
    if (mime == null) return;
    if (!_handled.add(path)) return; // create+move can fire for one capture
    if (_handled.length > 16) _handled.remove(_handled.first);

    // The event can fire while screencapture is still writing; settle briefly
    // and retry the read once if the file isn't complete yet.
    for (var attempt = 0; attempt < 2; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      try {
        final bytes = await File(path).readAsBytes();
        if (bytes.isNotEmpty) {
          onImage(bytes, mime);
          return;
        }
      } on FileSystemException {
        // Not readable yet (or gone) — retry once, then give up.
      }
    }
  }

  static String _desktop() => '${Platform.environment['HOME']}/Desktop';

  /// `defaults read com.apple.screencapture <key>`, null if unset/unreadable.
  static Future<String?> _readDefault(String key) async {
    try {
      final r = await Process.run(
        'defaults',
        ['read', 'com.apple.screencapture', key],
      );
      if (r.exitCode != 0) return null;
      final v = (r.stdout as String).trim();
      if (v.isEmpty) return null;
      // The location default may carry a trailing slash or a ~ prefix.
      final expanded = v.startsWith('~')
          ? v.replaceFirst('~', Platform.environment['HOME'] ?? '~')
          : v;
      return expanded.endsWith('/')
          ? expanded.substring(0, expanded.length - 1)
          : expanded;
    } catch (_) {
      return null;
    }
  }
}
