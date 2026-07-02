import 'package:meta/meta.dart';

/// A sealed clip ready to upload. No timestamp: the server stamps it on write
/// (FieldValue.serverTimestamp) so ordering never uses a device clock.
@immutable
class EncryptedClip {
  final String ciphertext;
  final String iv;
  final String hash;
  final String source;

  const EncryptedClip({
    required this.ciphertext,
    required this.iv,
    required this.hash,
    required this.source,
  });

  Map<String, dynamic> toMap() => {
        'ciphertext': ciphertext,
        'iv': iv,
        'hash': hash,
        'source': source,
      };

  factory EncryptedClip.fromMap(Map<String, dynamic> map) => EncryptedClip(
        ciphertext: map['ciphertext'] as String,
        iv: map['iv'] as String,
        hash: map['hash'] as String,
        source: map['source'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is EncryptedClip &&
      other.ciphertext == ciphertext &&
      other.iv == iv &&
      other.hash == hash &&
      other.source == source;

  @override
  int get hashCode => Object.hash(ciphertext, iv, hash, source);
}
