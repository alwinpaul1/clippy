import 'package:meta/meta.dart';

/// A clip delivered from the backend. [timestamp] is the resolved server
/// timestamp (the ClipStore converts the backend's timestamp to a DateTime).
@immutable
class RemoteClip {
  final String ciphertext;
  final String iv;
  final String hash;
  final String source;

  /// Human-friendly name of the origin device (cleartext, for display only).
  final String device;

  /// 'text' or 'image'; for images the decrypted plaintext is base64 JPEG.
  final String kind;
  final String mime;
  final DateTime timestamp;

  /// Pinned clips stay in history past the relay's cap and survive a clear.
  final bool pinned;

  const RemoteClip({
    required this.ciphertext,
    required this.iv,
    required this.hash,
    required this.source,
    required this.timestamp,
    this.device = '',
    this.kind = 'text',
    this.mime = '',
    this.pinned = false,
  });

  RemoteClip withPinned(bool p) => RemoteClip(
        ciphertext: ciphertext,
        iv: iv,
        hash: hash,
        source: source,
        timestamp: timestamp,
        device: device,
        kind: kind,
        mime: mime,
        pinned: p,
      );

  factory RemoteClip.fromMap(
    Map<String, dynamic> map, {
    required DateTime timestamp,
  }) =>
      RemoteClip(
        ciphertext: map['ciphertext'] as String,
        iv: map['iv'] as String,
        hash: map['hash'] as String,
        source: map['source'] as String,
        device: (map['device'] as String?) ?? '',
        kind: (map['kind'] as String?) ?? 'text',
        mime: (map['mime'] as String?) ?? '',
        timestamp: timestamp,
        pinned: map['pinned'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is RemoteClip &&
      other.ciphertext == ciphertext &&
      other.iv == iv &&
      other.hash == hash &&
      other.source == source &&
      other.device == device &&
      other.kind == kind &&
      other.mime == mime &&
      other.timestamp == timestamp &&
      other.pinned == pinned;

  @override
  int get hashCode =>
      Object.hash(
          ciphertext, iv, hash, source, device, kind, mime, timestamp, pinned);
}
