import 'dart:convert';

import 'package:clippy/core/crypto/aes_gcm_crypto_box.dart';
import 'package:clippy/core/models/remote_clip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Two distinct 32-byte master keys (as QR pairing would produce).
  final keyA = List<int>.filled(32, 11);
  final keyB = List<int>.filled(32, 22);
  final ts = DateTime.utc(2026);

  RemoteClip toRemote(clip) => RemoteClip(
        ciphertext: clip.ciphertext,
        iv: clip.iv,
        hash: clip.hash,
        source: clip.source,
        timestamp: ts,
      );

  test('fromMasterKey rejects a key that is not 32 bytes', () async {
    expect(() => AesGcmCryptoBox.fromMasterKey(List<int>.filled(16, 0)),
        throwsArgumentError);
  });

  test('isPaired is true for a constructed box', () async {
    final box = await AesGcmCryptoBox.fromMasterKey(keyA);
    expect(box.isPaired, isTrue);
  });

  test('seal then open round-trips on the same box', () async {
    final box = await AesGcmCryptoBox.fromMasterKey(keyA);
    final sealed = await box.seal('hello world', source: 'macA');
    expect(sealed.source, 'macA');
    expect(await box.open(toRemote(sealed)), 'hello world');
  });

  test('a second box built from the SAME master key can open the first\'s clip',
      () async {
    final mac = await AesGcmCryptoBox.fromMasterKey(keyA);
    final phone = await AesGcmCryptoBox.fromMasterKey(keyA);
    final sealed = await mac.seal('cross-device', source: 'macA');
    expect(await phone.open(toRemote(sealed)), 'cross-device');
  });

  test('opening with a DIFFERENT master key throws (wrong key)', () async {
    final mac = await AesGcmCryptoBox.fromMasterKey(keyA);
    final attacker = await AesGcmCryptoBox.fromMasterKey(keyB);
    final sealed = await mac.seal('secret', source: 'macA');
    expect(() => attacker.open(toRemote(sealed)), throwsA(anything));
  });

  test('fingerprint is deterministic and matches the sealed clip hash', () async {
    final box = await AesGcmCryptoBox.fromMasterKey(keyA);
    final fp = await box.fingerprint('abc');
    expect(await box.fingerprint('abc'), fp); // deterministic
    final sealed = await box.seal('abc', source: 'macA');
    expect(sealed.hash, fp); // seal uses the same fingerprint
  });

  test('different plaintext yields a different fingerprint', () async {
    final box = await AesGcmCryptoBox.fromMasterKey(keyA);
    expect(await box.fingerprint('abc'), isNot(await box.fingerprint('abd')));
  });

  test('same master key -> same fingerprint across boxes (echo-guard works)',
      () async {
    final mac = await AesGcmCryptoBox.fromMasterKey(keyA);
    final phone = await AesGcmCryptoBox.fromMasterKey(keyA);
    expect(await mac.fingerprint('x'), await phone.fingerprint('x'));
  });

  test('sealing the same text twice gives different ciphertext but same hash',
      () async {
    // Non-deterministic ciphertext (random nonce) so Firestore holds no
    // plaintext oracle; deterministic hash so the echo-guard still matches.
    final box = await AesGcmCryptoBox.fromMasterKey(keyA);
    final a = await box.seal('repeat', source: 'macA');
    final b = await box.seal('repeat', source: 'macA');
    expect(a.ciphertext, isNot(b.ciphertext));
    expect(a.iv, isNot(b.iv));
    expect(a.hash, b.hash);
  });

  test('ciphertext and iv are valid base64', () async {
    final box = await AesGcmCryptoBox.fromMasterKey(keyA);
    final sealed = await box.seal('data', source: 'macA');
    expect(() => base64.decode(sealed.ciphertext), returnsNormally);
    expect(() => base64.decode(sealed.iv), returnsNormally);
  });
}
