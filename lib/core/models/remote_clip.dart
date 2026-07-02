import 'package:meta/meta.dart';

/// A clip delivered from the backend. [timestamp] is the resolved server
/// timestamp (the ClipStore converts the backend's timestamp to a DateTime).
@immutable
class RemoteClip {
  final String ciphertext;
  final String iv;
  final String hash;
  final String source;
  final DateTime timestamp;

  const RemoteClip({
    required this.ciphertext,
    required this.iv,
    required this.hash,
    required this.source,
    required this.timestamp,
  });

  factory RemoteClip.fromMap(
    Map<String, dynamic> map, {
    required DateTime timestamp,
  }) =>
      RemoteClip(
        ciphertext: map['ciphertext'] as String,
        iv: map['iv'] as String,
        hash: map['hash'] as String,
        source: map['source'] as String,
        timestamp: timestamp,
      );

  @override
  bool operator ==(Object other) =>
      other is RemoteClip &&
      other.ciphertext == ciphertext &&
      other.iv == iv &&
      other.hash == hash &&
      other.source == source &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(ciphertext, iv, hash, source, timestamp);
}
