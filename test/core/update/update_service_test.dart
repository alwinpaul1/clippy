import 'dart:convert';
import 'dart:io';

import 'package:clippy/core/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

UpdateService svc(String body, {int code = 200}) => UpdateService(
      manifestUri: Uri.parse('https://relay.test/version.json'),
      currentVersion: () async => (version: '1.0.0', build: 1),
      client: MockClient((_) async => http.Response(body, code)),
    );

void main() {
  test('returns UpdateInfo when newer', () async {
    final u = await svc(jsonEncode({
      'version': '1.1.0',
      'build': 2,
      'notes': {
        'fixes': ['a'],
      },
    })).check();
    expect(u, isNotNull);
    expect(u!.version, '1.1.0');
    expect(u.fixes, ['a']);
  });

  test('null when same or older', () async {
    expect(await svc(jsonEncode({'version': '1.0.0', 'build': 1})).check(), isNull);
    expect(await svc(jsonEncode({'version': '0.9.0', 'build': 1})).check(), isNull);
  });

  test('null on http error', () async {
    expect(await svc('nope', code: 500).check(), isNull);
  });

  test('null on malformed json', () async {
    expect(await svc('not-json').check(), isNull);
  });

  // checkOrThrow — the manual "Check for updates" path must distinguish
  // "up to date" from a real failure (so Settings can say "Couldn't check").
  test('checkOrThrow throws on a non-200 manifest', () {
    expect(svc('nope', code: 500).checkOrThrow(), throwsA(anything));
  });

  test('checkOrThrow rethrows a network error (offline)', () {
    final s = UpdateService(
      manifestUri: Uri.parse('https://relay.test/version.json'),
      currentVersion: () async => (version: '1.0.0', build: 1),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    expect(s.checkOrThrow(), throwsA(anything));
  });

  test('checkOrThrow returns null when up to date', () async {
    expect(
      await svc(jsonEncode({'version': '1.0.0', 'build': 1})).checkOrThrow(),
      isNull,
    );
  });

  // Dismissal is keyed on version+build, so a build-only re-release of the
  // same semver is not permanently suppressed by dismissing the earlier build.
  test('dismissal round-trips on the version+build key', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final s = svc('{}');
    await s.dismiss('1.0.1+2');
    expect(await s.isDismissed('1.0.1+2'), isTrue);
    expect(await s.isDismissed('1.0.1+3'), isFalse); // build-only bump not hidden
  });

  group('artifactUri host pinning', () {
    final svc = UpdateService(
      manifestUri: Uri.parse('https://relay.clippy.app/version.json'),
      currentVersion: () async => (version: '1.0.0', build: 1),
    );

    test('a relative path resolves against the manifest origin', () {
      expect(svc.artifactUri('/download/Clippy-Android.apk').toString(),
          'https://relay.clippy.app/download/Clippy-Android.apk');
    });

    test('an absolute URL on the manifest host is accepted', () {
      expect(
          svc.artifactUri('https://relay.clippy.app/download/x.apk').host,
          'relay.clippy.app');
    });

    test('an absolute URL on ANOTHER host is REFUSED', () {
      // A tampered manifest must not be able to point the installer at an
      // attacker-controlled binary.
      expect(() => svc.artifactUri('https://evil.example/x.apk'),
          throwsA(isA<Exception>()));
    });

    test('same host but a DIFFERENT PORT is REFUSED', () {
      expect(
          () => svc.artifactUri('https://relay.clippy.app:8443/download/x.apk'),
          throwsA(isA<Exception>()),
          reason: 'a foothold on another port of the same host is exactly what '
              'the origin pin defends against');
    });
  });
}
