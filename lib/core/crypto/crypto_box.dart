import '../models/encrypted_clip.dart';
import '../models/remote_clip.dart';

/// Encrypts/decrypts clip payloads and computes the echo-guard fingerprint.
/// The fingerprint is HMAC(key, plaintext) — never a plaintext hash — so a
/// stored clip never carries a plaintext oracle. Real AES-256-GCM
/// implementation arrives in Plan 2; the core depends only on this interface.
abstract class CryptoBox {
  Future<EncryptedClip> seal(String plaintext, {required String source});
  Future<String> open(RemoteClip clip);
  Future<String> fingerprint(String plaintext);

  /// True once a shared key has been established (QR pairing, Plan 2).
  bool get isPaired;
}
