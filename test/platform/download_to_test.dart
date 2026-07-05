import 'dart:io';

import 'package:clippy/platform/updater/platform_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('downloadTo creates the destination parent dir when missing', () async {
    final tmp = Directory.systemTemp.createTempSync('clippy_dl_test');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // Mirrors getTemporaryDirectory() on a fresh macOS install: it returns
    // ~/Library/Caches/<bundle-id>, a directory that doesn't exist yet.
    final dest = File('${tmp.path}/does-not-exist-yet/Clippy-update.zip');
    expect(dest.parent.existsSync(), isFalse);

    final client = MockClient((_) async => http.Response('payload', 200));
    await downloadTo(
      Uri.parse('https://relay.test/Clippy-macOS.zip'),
      dest,
      client: client,
    );

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsStringSync(), 'payload');
  });
}
