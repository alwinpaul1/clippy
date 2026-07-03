import 'package:meta/meta.dart';

/// A sealed clip ready to upload. No timestamp: the server stamps it on write
/// (FieldValue.serverTimestamp) so ordering never uses a device clock.
@immutable
class EncryptedClip {
  final String ciphertext;
  final String iv;
  final String hash;
  final String source;

  /// Human-friendly name of the origin device (cleartext, for display only).
  final String device;

  /// 'text' or 'image' (cleartext, so a receiver knows how to handle the clip
  /// before decrypting). For images the sealed plaintext is base64 JPEG bytes.
  final String kind;

  /// MIME type for image clips, e.g. 'image/jpeg' (empty for text).
  final String mime;

  const EncryptedClip({
    required this.ciphertext,
    required this.iv,
    required this.hash,
    required this.source,
    this.device = '',
    this.kind = 'text',
    this.mime = '',
  });

  EncryptedClip copyWith({String? device, String? kind, String? mime}) =>
      EncryptedClip(
        ciphertext: ciphertext,
        iv: iv,
        hash: hash,
        source: source,
        device: device ?? this.device,
        kind: kind ?? this.kind,
        mime: mime ?? this.mime,
      );

  Map<String, dynamic> toMap() => {
        'ciphertext': ciphertext,
        'iv': iv,
        'hash': hash,
        'source': source,
        'device': device,
        'kind': kind,
        'mime': mime,
      };

  factory EncryptedClip.fromMap(Map<String, dynamic> map) => EncryptedClip(
        ciphertext: map['ciphertext'] as String,
        iv: map['iv'] as String,
        hash: map['hash'] as String,
        source: map['source'] as String,
        device: (map['device'] as String?) ?? '',
        kind: (map['kind'] as String?) ?? 'text',
        mime: (map['mime'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is EncryptedClip &&
      other.ciphertext == ciphertext &&
      other.iv == iv &&
      other.hash == hash &&
      other.source == source &&
      other.device == device &&
      other.kind == kind &&
      other.mime == mime;

  @override
  int get hashCode =>
      Object.hash(ciphertext, iv, hash, source, device, kind, mime);
}
