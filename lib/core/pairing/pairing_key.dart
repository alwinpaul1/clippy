import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../crypto/aes_gcm_crypto_box.dart';

/// The shared secret established by QR pairing: a single 256-bit master key
/// that every device in a group holds. From it we derive:
///   - the **room token** presented to the relay (HMAC(master, room label)),
///   - the **content keys** (via [AesGcmCryptoBox]) for E2E encryption.
/// The relay only ever sees the room token; the master key never leaves the
/// paired devices (it travels device-to-device inside the pairing QR).
class PairingKey {
  static const _roomLabel = 'clippy-relay-room-v1';

  final List<int> masterKey;

  PairingKey(this.masterKey) {
    if (masterKey.length != 32) {
      throw ArgumentError('master key must be 32 bytes, got ${masterKey.length}');
    }
  }

  /// Opaque relay credential derived from the master key. Two devices with the
  /// same key compute the same token and thus share a room.
  Future<String> roomToken() async {
    final mac = await Hmac.sha256()
        .calculateMac(utf8.encode(_roomLabel), secretKey: SecretKey(masterKey));
    return base64Url.encode(mac.bytes);
  }

  /// The E2E crypto box (separate enc/mac subkeys) for sealing/opening clips.
  Future<AesGcmCryptoBox> cryptoBox() =>
      AesGcmCryptoBox.fromMasterKey(masterKey);

  /// The value encoded into the pairing QR (base64 of the raw master key).
  String toQrPayload() => base64.encode(masterKey);

  factory PairingKey.fromQrPayload(String payload) =>
      PairingKey(base64.decode(payload.trim()));

  /// Creates a fresh random master key for a new device group.
  factory PairingKey.generate() {
    final rnd = Random.secure();
    return PairingKey(List<int>.generate(32, (_) => rnd.nextInt(256)));
  }
}
