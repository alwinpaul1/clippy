import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'update_info.dart';

/// Checks the relay's /version.json for a newer release and remembers which
/// versions the user dismissed. Pure of any UI; failures are swallowed on the
/// automatic path (returns null) — callers decide whether to surface an error.
class UpdateService {
  final Uri manifestUri;
  final Future<({String version, int build})> Function() _currentVersion;
  final http.Client _client;

  UpdateService({
    required this.manifestUri,
    required Future<({String version, int build})> Function() currentVersion,
    http.Client? client,
  })  : _currentVersion = currentVersion,
        _client = client ?? http.Client();

  static const _dismissKey = 'clippy.update.dismissed';

  /// Returns the manifest's [UpdateInfo] iff it is strictly newer than the
  /// running app; null if up to date. THROWS on a non-200 response, a network
  /// failure, or an unreadable manifest — so the manual "Check for updates"
  /// path can tell "up to date" apart from "couldn't reach the relay".
  Future<UpdateInfo?> checkOrThrow() async {
    final res = await _client.get(manifestUri);
    if (res.statusCode != 200) {
      throw Exception('manifest returned HTTP ${res.statusCode}');
    }
    final info = UpdateInfo.fromJson(
      (jsonDecode(res.body) as Map).cast<String, dynamic>(),
    );
    final cur = await _currentVersion();
    return info.isNewerThan(cur.version, cur.build) ? info : null;
  }

  /// Silent check (automatic/startup path): the manifest's [UpdateInfo] iff
  /// newer; null if up to date, offline, or the manifest is unreadable.
  Future<UpdateInfo?> check() async {
    try {
      return await checkOrThrow();
    } catch (_) {
      return null;
    }
  }

  /// Resolve an artifact path against the manifest's OWN origin. A relative
  /// path (what CI emits: `/download/...`) resolves against the manifest host.
  /// An absolute URL is accepted only if it names that same origin — a manifest
  /// must never be able to redirect the download to another host. Combined with
  /// the mandatory hash check in the updater, that keeps a tampered manifest
  /// from pointing clients at an attacker-controlled binary.
  Uri artifactUri(String pathOrUrl) {
    final u = Uri.parse(pathOrUrl);
    if (!u.hasScheme) return manifestUri.resolve(pathOrUrl);
    // Same ORIGIN: scheme, host, AND port. Pinning only host would let a
    // tampered manifest redirect to another port on the same machine — a
    // service an attacker with a foothold there could control.
    final sameOrigin = u.scheme == manifestUri.scheme &&
        u.host == manifestUri.host &&
        u.port == manifestUri.port;
    if (sameOrigin) return u;
    throw Exception('update artifact origin ${u.scheme}://${u.host}:${u.port} '
        'is not the manifest origin — refusing');
  }

  /// [key] is a `version+build` identifier (see [UpdateController]) so a
  /// build-only re-release of the same semver is not permanently suppressed by
  /// a dismissal of the earlier build.
  Future<void> dismiss(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dismissKey, key);
  }

  Future<bool> isDismissed(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_dismissKey) == key;
  }
}
