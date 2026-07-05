import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'android_updater.dart';
import 'desktop_updater.dart';

/// Downloads and applies an app update for the current platform. The URL is the
/// already-resolved absolute artifact URL (APK / macOS .app zip / Windows
/// installer). [onProgress] reports 0.0–1.0 during download.
abstract class PlatformUpdater {
  Future<void> update(Uri artifactUrl, {void Function(double)? onProgress});

  /// The updater for the running platform, or null where in-app update isn't
  /// supported (web, Linux) — callers fall back to opening the download page.
  static PlatformUpdater? forCurrent() {
    if (kIsWeb) return null;
    if (Platform.isAndroid) return _lazyAndroid();
    if (Platform.isMacOS || Platform.isWindows) return _lazyDesktop();
    return null;
  }

  static PlatformUpdater _lazyAndroid() => AndroidUpdater();
  static PlatformUpdater _lazyDesktop() => DesktopUpdater();
}

/// Streams [url] to [dest], reporting progress. Throws on a non-200 response.
Future<void> downloadTo(
  Uri url,
  File dest, {
  void Function(double)? onProgress,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final req = http.Request('GET', url);
    final res = await c.send(req);
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    // getTemporaryDirectory() can hand back a path whose directory doesn't
    // exist yet (e.g. ~/Library/Caches/<bundle-id> on a fresh macOS install),
    // so create the destination's parent before opening it for writing.
    dest.parent.createSync(recursive: true);
    final total = res.contentLength ?? 0;
    var received = 0;
    final sink = dest.openWrite();
    await for (final chunk in res.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }
    await sink.close();
  } finally {
    if (client == null) c.close();
  }
}
