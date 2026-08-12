import 'dart:io';

import 'package:clippy/platform/updater/desktop_updater.dart';
import 'package:flutter_test/flutter_test.dart';

/// The helper script that swaps `/Applications/Clippy.app` during a macOS
/// self-update. It runs detached, after the app has exited, so nothing in the
/// app can observe it failing — these tests are the only guard it has.
void main() {
  String script() => macUpdateScript(
        selfPid: 4242,
        newAppPath: '/tmp/clippy-update/clippy.app',
        installedApp: '/Applications/Clippy.app',
      );

  test('interpolates the real pid, not a literal shell variable', () {
    // A bare `$pid` renders empty, the wait loop never runs, and `rm -rf`
    // races the still-running app. The swap then fails silently.
    expect(script(), contains('kill -0 4242'));
    expect(script(), isNot(contains(r'$pid')));
  });

  test('refreshes the icon after the swap so macOS drops the cached one', () {
    final s = script();
    // `ditto` copies the zip's timestamps, so the new bundle can carry an mtime
    // OLDER than the icon macOS cached for that path. Without both lines the
    // Dock, Finder, Spotlight and Launchpad keep the previous release's icon.
    expect(s, contains('touch "/Applications/Clippy.app"'));
    expect(s, contains('lsregister -f "/Applications/Clippy.app"'));

    // Order matters: refreshing before the swap would register the OLD bundle.
    expect(s.indexOf('ditto "/tmp/clippy-update/clippy.app"'),
        lessThan(s.indexOf('touch "/Applications/Clippy.app"')));
    expect(s.indexOf('lsregister -f'), lessThan(s.indexOf('open ')));
  });

  test('a failed icon refresh never blocks the relaunch', () {
    // `set -e` is on. An unguarded touch or lsregister would abort the script
    // before `open`, and the user would be left with no running app.
    for (final line in script().split('\n')) {
      if (line.startsWith('#')) continue; // comments explain these commands
      if (line.startsWith('touch ') || line.contains('lsregister ')) {
        expect(line, endsWith('|| true'), reason: 'unguarded: $line');
      }
    }
  });

  test('lsregister is spelled as an absolute path that exists', () {
    const path = '/System/Library/Frameworks/CoreServices.framework/Frameworks'
        '/LaunchServices.framework/Support/lsregister';
    expect(script(), contains(path));
    if (Platform.isMacOS) {
      expect(File(path).existsSync(), isTrue,
          reason: 'macOS moved lsregister; the icon refresh is now a no-op');
    }
  });

  test('the generated script is valid bash', () async {
    final tmp = Directory.systemTemp.createTempSync('clippy_script_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File('${tmp.path}/helper.sh')..writeAsStringSync(script());

    final result = await Process.run('bash', ['-n', f.path]);
    expect(result.exitCode, 0, reason: 'bash -n said: ${result.stderr}');
  }, skip: Platform.isWindows ? 'no bash on Windows runners' : false);
}
