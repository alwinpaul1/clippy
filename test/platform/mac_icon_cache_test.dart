import 'dart:io';

import 'package:clippy/platform/updater/mac_icon_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Startup half of the macOS icon fix. It re-registers the app bundle with
/// LaunchServices once per build, so an install that arrived through an older
/// updater stops showing the previous release's icon.
///
/// Every test drives the seams, never the real platform. CI runs this suite on
/// `ubuntu-latest`, so a test that relied on Platform.isMacOS would take the
/// early return and pass while proving nothing.
void main() {
  const key = 'mac_icon_refresh_build';
  const appPath = '/Applications/Clippy.app';
  const exePath = '$appPath/Contents/MacOS/clippy';

  late List<List<String>> calls;

  /// Records every command and returns [exitCode] for lsregister.
  void stubProcesses({int exitCode = 0}) {
    calls = [];
    MacIconCache.runProcess = (cmd, args) async {
      calls.add([cmd, ...args]);
      final isTouch = cmd == 'touch';
      return ProcessResult(0, isTouch ? 0 : exitCode, '', '');
    };
  }

  setUp(() {
    MacIconCache.isMacOS = () => true;
    MacIconCache.resolvedExecutable = () => exePath;
    PackageInfo.setMockInitialValues(
      appName: 'Clippy',
      packageName: 'me.alwinpaul.clippy',
      version: '1.5.0',
      buildNumber: '61',
      buildSignature: '',
    );
    stubProcesses();
  });

  tearDown(() {
    MacIconCache.runProcess = Process.run;
    MacIconCache.isMacOS = () => Platform.isMacOS;
    MacIconCache.resolvedExecutable = () => Platform.resolvedExecutable;
  });

  test('refreshes the bundle and records the build on the first launch',
      () async {
    SharedPreferences.setMockInitialValues({});
    await MacIconCache.refreshForNewBuild();

    expect(calls.length, 2);
    expect(calls[0], ['touch', appPath]);
    expect(calls[1].first, endsWith('lsregister'));
    expect(calls[1].sublist(1), ['-f', appPath]);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(key), '61');
  });

  test('a FAILED lsregister is not recorded, so the next launch retries',
      () async {
    // The regression this test exists for: Process.run does NOT throw on a
    // nonzero exit. Recording the build here would leave that install showing
    // the old icon for good, which is the bug the class exists to prevent.
    SharedPreferences.setMockInitialValues({});
    stubProcesses(exitCode: 1);

    await MacIconCache.refreshForNewBuild();

    expect(calls.length, 2, reason: 'it must still attempt the refresh');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(key), isNull,
        reason: 'a failed refresh must not be recorded as done');
  });

  test('does nothing when this build was already refreshed', () async {
    SharedPreferences.setMockInitialValues({key: '61'});
    await MacIconCache.refreshForNewBuild();
    expect(calls, isEmpty);
  });

  test('refreshes again when the build number changes', () async {
    SharedPreferences.setMockInitialValues({key: '60'});
    await MacIconCache.refreshForNewBuild();

    expect(calls.length, 2);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(key), '61');
  });

  test('is a no-op off macOS — Windows and Linux must not be touched',
      () async {
    SharedPreferences.setMockInitialValues({});
    MacIconCache.isMacOS = () => false;

    await MacIconCache.refreshForNewBuild();

    expect(calls, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(key), isNull);
  });

  test('runs nothing when the executable is not inside a .app bundle',
      () async {
    // A debug/test run, not an installed bundle. Touching whatever three
    // directories up happens to be would be wrong.
    SharedPreferences.setMockInitialValues({});
    MacIconCache.resolvedExecutable = () => '/usr/local/bin/clippy';

    await MacIconCache.refreshForNewBuild();

    expect(calls, isEmpty);
  });

  test('a throwing process never breaks startup', () async {
    SharedPreferences.setMockInitialValues({});
    MacIconCache.runProcess = (_, _) async => throw const ProcessException(
        'lsregister', [], 'no such file', 2);

    await expectLater(MacIconCache.refreshForNewBuild(), completes);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(key), isNull);
  });
}
