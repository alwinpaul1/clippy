import 'package:flutter/services.dart';

import '../core/history/clipboard_writer.dart';
import 'native_clip_writer.dart';

/// Writes to the real system clipboard via Flutter's platform channel.
/// Implements the core ClipboardWriter seam so HistoryStore's apply-on-tap
/// puts a chosen clip onto the OS clipboard. On Android the native writer goes
/// first so the accessibility service recognises the write as ours.
class FlutterClipboardWriter implements ClipboardWriter {
  const FlutterClipboardWriter();

  @override
  Future<void> setText(String text) async {
    if (await NativeClipWriter.writeText(text)) return;
    await Clipboard.setData(ClipboardData(text: text));
  }
}
