import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'platform_updater.dart';

/// Downloads the release APK and hands it to Android's system installer, which
/// updates the existing app in place (same signing key). The user grants
/// "install unknown apps" once on first use.
class AndroidUpdater implements PlatformUpdater {
  static const _channel = MethodChannel('clippy/update');

  @override
  Future<void> update(Uri artifactUrl, {void Function(double)? onProgress}) async {
    final base = await getApplicationSupportDirectory(); // == filesDir
    final dir = Directory('${base.path}/updates');
    dir.createSync(recursive: true);
    final apk = File('${dir.path}/clippy-update.apk');
    if (apk.existsSync()) apk.deleteSync();

    await downloadTo(artifactUrl, apk, onProgress: onProgress);

    await _channel.invokeMethod('installApk', {'path': apk.path});
  }
}
