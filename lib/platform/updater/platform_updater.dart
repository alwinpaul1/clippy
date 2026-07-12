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

/// Thrown when a downloaded artifact's SHA-256 does not match the manifest's —
/// i.e. the bytes were TAMPERED with (a completed download whose content is
/// wrong). A truncated download is a [DownloadException] instead, so a flaky
/// network is never mistaken for an attack. The file is deleted before either
/// is raised — a bad binary is never left where an install path could pick it
/// up.
class IntegrityException implements Exception {
  IntegrityException(this.expected, this.actual);
  final String expected;
  final String actual;
  @override
  String toString() =>
      'update artifact failed its integrity check '
      '(expected $expected, got $actual) — refusing to install';
}

/// A download that could not complete or was misconfigured — retryable, and NOT
/// evidence of tampering. Covers a truncated stream and a malformed manifest
/// hash. Callers fall back to the download page.
class DownloadException implements Exception {
  DownloadException(this.message);
  final String message;
  @override
  String toString() => 'update download failed: $message';
}

/// No real artifact comes close to this; a stream past it is a runaway or a
/// hostile endpoint, and is cut off before it can fill the disk.
const _maxArtifactBytes = 400 * 1024 * 1024;

final _hex64 = RegExp(r'^[0-9a-f]{64}$');

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
  int maxBytes = _maxArtifactBytes,
}) async {
  // Validate the expected hash BEFORE spending a download on it. A malformed
  // manifest hash (stray space, wrong case, a `sha256:` prefix) is a manifest
  // problem, not tampering — and reporting it as such lets the UI fall back to
  // the download page instead of crying wolf.
  final expected = expectedSha256.trim().toLowerCase();
  if (!_hex64.hasMatch(expected)) {
    throw DownloadException('manifest hash is not a 64-char hex SHA-256');
  }
  final c = client ?? http.Client();
  final hashSink = Sha256().newHashSink();
  var ok = false;
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
        if (received > maxBytes) {
          throw DownloadException('artifact exceeds the size limit');
        }
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      // Close even if the stream errors mid-download, so a dropped connection
      // doesn't leak the file handle onto the partial artifact.
      await sink.close();
    }
    // A stream can end SHORT of its declared length without throwing (the socket
    // closed mid-download). That is a truncated file, not a tampered one — the
    // common failure on a slow mobile link. Say so, so it is retried rather than
    // mistaken for an attack. (Over-length is anomalous/hostile, but reported as
    // its own thing rather than mislabelled "truncated".)
    if (total > 0 && received != total) {
      final how = received < total ? 'truncated' : 'over-length';
      throw DownloadException('download $how ($received of $total bytes)');
    }
    hashSink.close();
    final actual = base16((await hashSink.hash()).bytes);
    if (actual != expected) throw IntegrityException(expected, actual);
    ok = true;
  } finally {
    if (client == null) c.close();
    // Delete the partial/bad artifact on ANY failure, not just a hash mismatch:
    // the desktop updaters reuse a fixed filename, so a leftover could be handed
    // to the installer on a later run.
    if (!ok) {
      try {
        if (dest.existsSync()) dest.deleteSync();
      } catch (_) {}
    }
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
