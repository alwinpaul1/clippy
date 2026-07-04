import 'package:flutter_test/flutter_test.dart';
import 'package:clippy/core/update/update_info.dart';

void main() {
  test('compareSemver orders numerically not lexically', () {
    expect(compareSemver('1.2.0', '1.10.0'), -1);
    expect(compareSemver('1.0.1', '1.0.0'), 1);
    expect(compareSemver('1.0.0', '1.0.0'), 0);
    expect(compareSemver('2.0.0', '1.9.9'), 1);
  });

  test('compareSemver ignores build suffix', () {
    expect(compareSemver('1.0.0+5', '1.0.0+1'), 0);
  });

  test('isNewerThan uses version then build', () {
    final u = UpdateInfo.fromJson({'version': '1.1.0', 'build': 5, 'notes': {}});
    expect(u.isNewerThan('1.0.0', 1), true);
    expect(u.isNewerThan('1.1.0', 4), true); // same version, higher build
    expect(u.isNewerThan('1.1.0', 5), false); // equal
    expect(u.isNewerThan('1.1.0', 6), false); // lower build
    expect(u.isNewerThan('1.2.0', 1), false); // older manifest
  });

  test('isBugUpdate when features empty', () {
    final bug = UpdateInfo.fromJson({
      'version': '1.0.1',
      'build': 2,
      'notes': {
        'fixes': ['x'],
      },
    });
    expect(bug.isBugUpdate, true);
    final feat = UpdateInfo.fromJson({
      'version': '1.1.0',
      'build': 3,
      'notes': {
        'features': ['y'],
      },
    });
    expect(feat.isBugUpdate, false);
  });

  test('fromJson tolerates missing notes/urls', () {
    final u = UpdateInfo.fromJson({'version': '1.0.0', 'build': 1});
    expect(u.features, isEmpty);
    expect(u.improvements, isEmpty);
    expect(u.fixes, isEmpty);
    expect(u.androidUrl, isNull);
    expect(u.macosUrl, isNull);
  });

  test('fromJson parses notes and urls', () {
    final u = UpdateInfo.fromJson({
      'version': '1.1.0',
      'build': 5,
      'notes': {
        'features': ['a'],
        'improvements': ['b', 'c'],
        'fixes': ['d'],
      },
      'android': '/download/Clippy-Android.apk',
      'macos': '/download/Clippy-macOS.zip',
      'windows': '/download/Clippy-Setup.exe',
    });
    expect(u.features, ['a']);
    expect(u.improvements, ['b', 'c']);
    expect(u.fixes, ['d']);
    expect(u.androidUrl, '/download/Clippy-Android.apk');
    expect(u.windowsUrl, '/download/Clippy-Setup.exe');
  });
}
