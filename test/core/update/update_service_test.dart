import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:clippy/core/update/update_service.dart';

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
}
