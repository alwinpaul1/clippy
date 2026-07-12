import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'android_updater.dart';
import 'desktop_updater.dart';

/// Downloads and applies an app update for the current platform. The URL is the
/// already-resolved absolute artifact URL (APK / macOS .app zip / Windows
/// installer). [onProgress] reports 0.0–1.0 during download.
abstract class PlatformUpdater {
  /// [sha256] is the artifact's expected hex digest, from the signed-by-CI
  /// manifest. It is REQUIRED, not optional: this method downloads and installs
  /// an executable, and skipping the check whenever a hash is absent would hand
  /// a network attacker a trivial bypass (strip the field). No hash → no update.
  Future<void> update(Uri artifactUrl,
      {required String sha256, void Function(double)? onProgress});

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

/// Thrown when a downloaded artifact's SHA-256 does not match the manifest's.
/// The file is deleted before this is raised — a tampered or corrupt binary is
/// never left on disk where an install path might pick it up.
class IntegrityException implements Exception {
  IntegrityException(this.expected, this.actual);
  final String expected;
  final String actual;
  @override
  String toString() =>
      'update artifact failed its integrity check '
      '(expected $expected, got $actual) — refusing to install';
}

/// Streams [url] to [dest], reporting progress, AND verifies its SHA-256 against
/// [expectedSha256] before returning. Throws on a non-200 response; throws
/// [IntegrityException] (after deleting the file) on a hash mismatch.
///
/// The hash is computed AS the bytes stream past, so an 80MB APK is never read
/// from disk a second time. This is the only integrity gate for macOS and
/// Windows — Android additionally has the system installer's signing-key check,
/// but the desktop platforms have nothing else between the network and running
/// code.
Future<void> downloadTo(
  Uri url,
  File dest, {
  required String expectedSha256,
  void Function(double)? onProgress,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  final hashSink = Sha256().newHashSink();
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
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        hashSink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      // Close even if the stream errors mid-download, so a dropped connection
      // doesn't leak the file handle onto the partial artifact.
      await sink.close();
    }
    hashSink.close();
    final actual = base16((await hashSink.hash()).bytes);
    if (actual != expectedSha256.toLowerCase()) {
      try {
        dest.deleteSync();
      } catch (_) {}
      throw IntegrityException(expectedSha256.toLowerCase(), actual);
    }
  } finally {
    if (client == null) c.close();
  }
}

/// Lowercase hex, matching `sha256sum` / Python `hashlib.sha256().hexdigest()`.
String base16(List<int> bytes) {
  const digits = '0123456789abcdef';
  final sb = StringBuffer();
  for (final b in bytes) {
    sb..write(digits[(b >> 4) & 0xf])..write(digits[b & 0xf]);
  }
  return sb.toString();
}
