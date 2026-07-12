import 'dart:io';

import 'package:clippy/platform/updater/platform_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cryptography/cryptography.dart';

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
      expectedSha256: '239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5',
      client: client,
    );

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsStringSync(), 'payload');
  });

  test('a matching SHA-256 passes; a mismatch throws and DELETES the file',
      () async {
    final tmp = Directory.systemTemp.createTempSync('clippy_dl_hash');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final dest = File('${tmp.path}/artifact.bin');
    final client = MockClient((_) async => http.Response('the real binary', 200));

    // Wrong hash — a tampered or corrupt download.
    await expectLater(
      downloadTo(Uri.parse('https://relay.test/x'), dest,
          expectedSha256: 'deadbeef' * 8, client: client),
      throwsA(isA<IntegrityException>()),
    );
    expect(dest.existsSync(), isFalse,
        reason: 'a binary that failed its integrity check must never be left on '
            'disk where an install path could pick it up');

    // Right hash — installs.
    final good = hex(await Sha256().hash('the real binary'.codeUnits));
    await downloadTo(Uri.parse('https://relay.test/x'), dest,
        expectedSha256: good, client: client);
    expect(dest.readAsStringSync(), 'the real binary');
  });
}

String hex(Hash h) => base16(h.bytes);
