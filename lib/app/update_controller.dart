import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/update/update_info.dart';
import '../core/update/update_service.dart';
import '../platform/updater/platform_updater.dart';
import 'relay_config.dart';

/// Outcome of a manual "Check for updates".
enum CheckResult { updateAvailable, upToDate, failed }

/// App-wide in-app-update state: checks the relay manifest, holds the available
/// update, and runs the platform installer. A single shared instance ([updater])
/// keeps the cross-cutting check out of the widget constructors.
class UpdateController {
  UpdateController({UpdateService? service})
      : _service = service ?? UpdateService(
          manifestUri: _manifestUri(),
          currentVersion: _currentVersion,
        );

  final UpdateService _service;

  /// The available update, or null when up to date / not yet checked.
  final ValueNotifier<UpdateInfo?> available = ValueNotifier(null);

  static Uri _manifestUri() {
    final u = Uri.parse(relayUrl);
    return Uri(
      scheme: u.scheme == 'ws' ? 'http' : 'https', // wss -> https
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: '/version.json',
    );
  }

  static Future<({String version, int build})> _currentVersion() async {
    final info = await PackageInfo.fromPlatform();
    return (
      version: info.version,
      build: int.tryParse(info.buildNumber) ?? 0,
    );
  }

  /// Silent startup check — surfaces the banner only if not already dismissed.
  Future<void> checkOnStartup() async {
    final info = await _service.check();
    if (info == null) return;
    if (await _service.isDismissed('${info.version}+${info.build}')) return;
    available.value = info;
  }

  /// Manual check (Settings). Always surfaces the update even if dismissed.
  Future<CheckResult> checkNow() async {
    try {
      final info = await _service.checkOrThrow();
      if (info == null) return CheckResult.upToDate;
      available.value = info;
      return CheckResult.updateAvailable;
    } catch (_) {
      return CheckResult.failed;
    }
  }

  Future<void> dismiss() async {
    final info = available.value;
    if (info != null) await _service.dismiss('${info.version}+${info.build}');
    available.value = null;
  }

  /// Resolved artifact URL for the current platform, or null if none applies.
  Uri? artifactUrl(UpdateInfo info) {
    final path = kIsWeb
        ? null
        : (defaultTargetPlatform == TargetPlatform.android
            ? info.androidUrl
            : defaultTargetPlatform == TargetPlatform.macOS
                ? info.macosUrl
                : defaultTargetPlatform == TargetPlatform.windows
                    ? info.windowsUrl
                    : null);
    return path == null ? null : _service.artifactUri(path);
  }

  /// Downloads and applies the update. Throws on failure (caller shows an error
  /// and can fall back to the download page).
  Future<void> runUpdate(
    UpdateInfo info, {
    void Function(double)? onProgress,
  }) async {
    final updater = PlatformUpdater.forCurrent();
    final url = artifactUrl(info);
    if (updater == null || url == null) {
      throw Exception('In-app update unavailable on this platform');
    }
    await updater.update(url, onProgress: onProgress);
  }
}

/// Shared app-wide instance.
final UpdateController updater = UpdateController();
