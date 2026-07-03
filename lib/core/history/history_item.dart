import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A decrypted entry in the browsable clipboard history (spec §4.2, §7.1).
/// Shown in the macOS menu, the Android floating bubble, and the Clippy app.
@immutable
class HistoryItem {
  final String text;
  final String hash;
  final String source;

  /// Human-friendly name of the origin device (may be empty for older clips).
  final String device;

  /// 'text' or 'image'.
  final String kind;
  final String mime;

  /// Decoded JPEG bytes for image clips (null for text), ready for
  /// Image.memory and clipboard writes.
  final Uint8List? imageBytes;
  final DateTime timestamp;

  const HistoryItem({
    required this.text,
    required this.hash,
    required this.source,
    required this.timestamp,
    this.device = '',
    this.kind = 'text',
    this.mime = '',
    this.imageBytes,
  });

  bool get isImage => kind == 'image';
}
