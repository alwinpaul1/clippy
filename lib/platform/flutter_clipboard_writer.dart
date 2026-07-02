import 'package:flutter/services.dart';

import '../core/history/clipboard_writer.dart';

/// Writes to the real system clipboard via Flutter's platform channel.
/// Implements the core ClipboardWriter seam so HistoryStore's apply-on-tap
/// puts a chosen clip onto the OS clipboard.
class FlutterClipboardWriter implements ClipboardWriter {
  const FlutterClipboardWriter();

  @override
  Future<void> setText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}
