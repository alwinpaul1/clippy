import 'package:meta/meta.dart';

/// A decrypted entry in the browsable clipboard history (spec §4.2, §7.1).
/// Shown in the macOS menu, the Android floating bubble, and the Clippy app.
@immutable
class HistoryItem {
  final String text;
  final String hash;
  final String source;
  final DateTime timestamp;

  const HistoryItem({
    required this.text,
    required this.hash,
    required this.source,
    required this.timestamp,
  });
}
