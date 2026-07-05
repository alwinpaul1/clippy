import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';

import '../models/encrypted_clip.dart';
import '../models/remote_clip.dart';
import 'crypto_box.dart';

/// Real end-to-end encryption for clip payloads (spec §8).
///
/// A single 32-byte master key is established once by QR pairing and stored in
/// the OS keystore (Plan 2/3/4). From it we derive two independent subkeys so
/// the same key is never reused across primitives:
///   encKey = HMAC-SHA256(master, "clippy-enc-v1")   // AES-256-GCM
///   macKey = HMAC-SHA256(master, "clippy-mac-v1")   // fingerprint HMAC
/// (This is HKDF-Expand with a single 32-byte output block.)
///
/// Storage format in [EncryptedClip]:
///   iv         = base64(12-byte GCM nonce)
///   ciphertext = base64(cipherText || 16-byte GCM MAC)
///   hash       = base64(HMAC-SHA256(macKey, plaintext))  // echo-guard key,
///                deterministic per plaintext but not a plaintext oracle.
class AesGcmCryptoBox implements CryptoBox {
  static const _encLabel = 'clippy-enc-v1';
  static const _macLabel = 'clippy-mac-v1';
  static const _gcmMacLength = 16;

  final AesGcm _aes = AesGcm.with256bits();
  final Hmac _hmac = Hmac.sha256();
  final SecretKey _encKey;
  final SecretKey _macKey;

  AesGcmCryptoBox._(this._encKey, this._macKey);

  /// Derives the enc/mac subkeys from a 32-byte paired master key.
  static Future<AesGcmCryptoBox> fromMasterKey(List<int> masterKeyBytes) async {
    if (masterKeyBytes.length != 32) {
      throw ArgumentError('master key must be 32 bytes, got '
          '${masterKeyBytes.length}');
    }
    final master = SecretKey(masterKeyBytes);
    final hmac = Hmac.sha256();
    final enc =
        await hmac.calculateMac(utf8.encode(_encLabel), secretKey: master);
    final mac =
        await hmac.calculateMac(utf8.encode(_macLabel), secretKey: master);
    return AesGcmCryptoBox._(SecretKey(enc.bytes), SecretKey(mac.bytes));
  }

  @override
  bool get isPaired => true;

  @override
  Future<String> fingerprint(String plaintext) async {
    final mac =
        await _hmac.calculateMac(utf8.encode(plaintext), secretKey: _macKey);
    return base64.encode(mac.bytes);
  }

  @override
  Future<EncryptedClip> seal(String plaintext, {required String source}) async {
    final box = await _aes.encrypt(utf8.encode(plaintext), secretKey: _encKey);
    final blob = <int>[...box.cipherText, ...box.mac.bytes];
    return EncryptedClip(
      ciphertext: base64.encode(blob),
      iv: base64.encode(box.nonce),
      hash: await fingerprint(plaintext),
      source: source,
    );
  }

  @override
  Future<String> open(RemoteClip clip) async {
    final blob = base64.decode(clip.ciphertext);
    final nonce = base64.decode(clip.iv);
    if (blob.length < _gcmMacLength) {
      throw const FormatException('ciphertext shorter than GCM MAC');
    }
    final cipherText = blob.sublist(0, blob.length - _gcmMacLength);
    final macBytes = blob.sublist(blob.length - _gcmMacLength);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
    final clear = await _aes.decrypt(box, secretKey: _encKey);
    return utf8.decode(clear);
  }

  @override
  Future<List<String>> openAll(List<RemoteClip> clips) async {
    if (clips.isEmpty) return const [];
    // AES-GCM here is pure-Dart and CPU-bound; decrypting a whole snapshot
    // (esp. image clips, MBs each) on the UI isolate freezes the loading
    // spinner. Extract the raw key and run the batch on a throwaway isolate so
    // the UI isolate stays free. The key never leaves the app; the spawned
    // isolate is pure computation (no platform channels), so this is portable
    // across macOS / Windows / Android.
    final keyBytes = await _encKey.extractBytes();
    final payloads = [
      for (final c in clips) (c.ciphertext, c.iv),
    ];
    return Isolate.run(() => _decryptBatch(keyBytes, payloads));
  }
}

/// Runs on a background isolate (see [AesGcmCryptoBox.openAll]). Rebuilds the
/// cipher from the raw key bytes and decrypts each (ciphertext, iv) payload,
/// returning plaintexts in order. Throws on the first undecryptable clip.
Future<List<String>> _decryptBatch(
  List<int> keyBytes,
  List<(String, String)> payloads,
) async {
  final aes = AesGcm.with256bits();
  final key = SecretKey(keyBytes);
  final out = <String>[];
  for (final (ciphertext, iv) in payloads) {
    final blob = base64.decode(ciphertext);
    final nonce = base64.decode(iv);
    if (blob.length < AesGcmCryptoBox._gcmMacLength) {
      throw const FormatException('ciphertext shorter than GCM MAC');
    }
    final cut = blob.length - AesGcmCryptoBox._gcmMacLength;
    final box = SecretBox(
      blob.sublist(0, cut),
      nonce: nonce,
      mac: Mac(blob.sublist(cut)),
    );
    out.add(utf8.decode(await aes.decrypt(box, secretKey: key)));
  }
  return out;
}
