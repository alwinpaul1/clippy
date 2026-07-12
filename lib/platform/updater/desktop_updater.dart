import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'platform_updater.dart';

/// Seamless desktop self-update.
///  - macOS: download the new `.app` (a zip), then a detached helper waits for
///    this process to exit, swaps `/Applications/Clippy.app`, and relaunches.
///  - Windows: download the Inno Setup installer and run it silently; it
///    replaces the install and restarts the app.
class DesktopUpdater implements PlatformUpdater {
  @override
  Future<void> update(Uri artifactUrl,
      {required String sha256, void Function(double)? onProgress}) async {
    final tmp = await getTemporaryDirectory();
    if (Platform.isMacOS) {
      await _updateMac(artifactUrl, sha256, tmp, onProgress);
    } else if (Platform.isWindows) {
      await _updateWindows(artifactUrl, sha256, tmp, onProgress);
    }
  }

  Future<void> _updateMac(
    Uri url,
    String sha256,
    Directory tmp,
    void Function(double)? onProgress,
  ) async {
    final zip = File('${tmp.path}/Clippy-update.zip');
    await downloadTo(url, zip, expectedSha256: sha256, onProgress: onProgress);

    final extractDir = Directory('${tmp.path}/clippy-update')
      ..createSync(recursive: true);
    final unzip = await Process.run('ditto', [
      '-x', '-k', zip.path, extractDir.path,
    ]);
    if (unzip.exitCode != 0) throw Exception('unzip failed: ${unzip.stderr}');

    // The zip keeps the parent, so the app is at <extractDir>/clippy.app.
    final newApp = Directory('${extractDir.path}/clippy.app');
    if (!newApp.existsSync()) throw Exception('no .app in update');

    // Current install: resolvedExecutable is <app>/Contents/MacOS/clippy.
    final exe = File(Platform.resolvedExecutable);
    final installedApp = exe.parent.parent.parent.path; // -> Clippy.app

    // Detached helper: wait for us to quit, swap the bundle, relaunch.
    final helper = File('${tmp.path}/clippy-update.sh');
    helper.writeAsStringSync('''#!/bin/bash
while kill -0 $pid 2>/dev/null; do sleep 0.3; done
rm -rf "$installedApp"
ditto "${newApp.path}" "$installedApp"
open "$installedApp"
''');
    await Process.run('chmod', ['+x', helper.path]);
    await Process.start('/bin/bash', [helper.path], mode: ProcessStartMode.detached);
    exit(0);
  }

  Future<void> _updateWindows(
    Uri url,
    String sha256,
    Directory tmp,
    void Function(double)? onProgress,
  ) async {
    final setup = File('${tmp.path}\\Clippy-Setup.exe');
    await downloadTo(url, setup, expectedSha256: sha256, onProgress: onProgress);
    // Inno Setup: silent install, close the running app. The installer's [Run]
    // entry relaunches Clippy when it finishes (its skipifsilent flag was
    // removed so silent updates reopen the app — Restart Manager can't, as a
    // Flutter app doesn't register with it). /NORESTART: never reboot Windows.
    await Process.start(
      setup.path,
      ['/SILENT', '/CLOSEAPPLICATIONS', '/NORESTART'],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}
