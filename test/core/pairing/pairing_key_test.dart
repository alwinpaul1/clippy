import 'dart:convert';

import 'package:clippy/core/pairing/pairing_key.dart';
import 'package:clippy/core/models/remote_clip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final keyA = List<int>.filled(32, 5);
  final keyB = List<int>.filled(32, 9);

  test('rejects a master key that is not 32 bytes', () {
    expect(() => PairingKey(List<int>.filled(16, 0)), throwsArgumentError);
  });

  test('roomToken is deterministic for a given key', () async {
    final t1 = await PairingKey(keyA).roomToken();
    final t2 = await PairingKey(keyA).roomToken();
    expect(t1, t2);
    expect(t1, isNotEmpty);
  });

  test('different keys produce different room tokens', () async {
    expect(await PairingKey(keyA).roomToken(),
        isNot(await PairingKey(keyB).roomToken()));
  });

  test('room token is not equal to a content fingerprint (label separation)',
      () async {
    // The room token must not leak the content-key derivation.
    final pk = PairingKey(keyA);
    final box = await pk.cryptoBox();
    final token = await pk.roomToken();
    final fp = await box.fingerprint('anything');
    expect(token, isNot(fp));
  });

  test('QR payload round-trips back to the same key and token', () async {
    final pk = PairingKey(keyA);
    final payload = pk.toQrPayload();
    final restored = PairingKey.fromQrPayload(payload);
    expect(restored.masterKey, keyA);
    expect(await restored.roomToken(), await pk.roomToken());
  });

  test('cryptoBox from the same key can seal and open a clip', () async {
    final box = await PairingKey(keyA).cryptoBox();
    final sealed = await box.seal('hi', source: 'devA');
    final rc = RemoteClip(
      ciphertext: sealed.ciphertext,
      iv: sealed.iv,
      hash: sealed.hash,
      source: sealed.source,
      timestamp: DateTime.utc(2026),
    );
    expect(await box.open(rc), 'hi');
  });

  test('generate produces a 32-byte key, different each time', () {
    final a = PairingKey.generate();
    final b = PairingKey.generate();
    expect(a.masterKey.length, 32);
    expect(a.masterKey, isNot(b.masterKey));
  });

  test('QR payload is valid base64', () {
    final payload = PairingKey(keyA).toQrPayload();
    expect(() => base64.decode(payload), returnsNormally);
  });
}
