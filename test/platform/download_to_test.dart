import 'dart:io';

import 'package:clippy/platform/updater/platform_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
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

  test('a TRUNCATED download is a DownloadException, not an integrity alarm',
      () async {
    final tmp = Directory.systemTemp.createTempSync('clippy_dl_trunc');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final dest = File('${tmp.path}/a.bin');
    // Server declares 100 bytes, socket delivers 5.
    final client = MockClient.streaming(
        (req, body) async => _streamed([1, 2, 3, 4, 5], contentLength: 100));

    await expectLater(
      downloadTo(Uri.parse('https://relay.test/x'), dest,
          expectedSha256: '0' * 64, client: client),
      throwsA(isA<DownloadException>()),
    );
    expect(dest.existsSync(), isFalse,
        reason: 'a partial download must not be left for the installer');
  });

  test('a malformed manifest hash fails fast as a DownloadException (no fetch)',
      () async {
    final tmp = Directory.systemTemp.createTempSync('clippy_dl_badhash');
    addTearDown(() => tmp.deleteSync(recursive: true));
    var fetched = false;
    final client = MockClient((_) async {
      fetched = true;
      return http.Response('x', 200);
    });

    await expectLater(
      downloadTo(Uri.parse('https://relay.test/x'),
          File('${tmp.path}/a.bin'),
          expectedSha256: 'not-a-hash', client: client),
      throwsA(isA<DownloadException>()),
    );
    expect(fetched, isFalse, reason: 'a bad hash is rejected before spending a '
        'download on it');
  });

  test('an oversized stream is cut off before it can fill the disk', () async {
    final tmp = Directory.systemTemp.createTempSync('clippy_dl_big');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final dest = File('${tmp.path}/a.bin');
    final client = MockClient.streaming(
        (req, body) async => _streamed(List.filled(50, 0)));

    await expectLater(
      downloadTo(Uri.parse('https://relay.test/x'), dest,
          expectedSha256: '0' * 64, client: client, maxBytes: 10),
      throwsA(isA<DownloadException>()),
    );
    expect(dest.existsSync(), isFalse);
  });

  test('a non-200 leaves nothing on disk', () async {
    final tmp = Directory.systemTemp.createTempSync('clippy_dl_404');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final dest = File('${tmp.path}/a.bin');
    final client = MockClient((_) async => http.Response('nope', 404));

    await expectLater(
      downloadTo(Uri.parse('https://relay.test/x'), dest,
          expectedSha256: '0' * 64, client: client),
      throwsA(anything),
    );
    expect(dest.existsSync(), isFalse);
  });
}

http.StreamedResponse _streamed(List<int> bytes, {int? contentLength}) =>
    http.StreamedResponse(Stream.value(bytes), 200,
        contentLength: contentLength ?? bytes.length);

String hex(Hash h) => base16(h.bytes);
