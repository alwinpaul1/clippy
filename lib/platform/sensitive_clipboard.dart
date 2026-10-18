import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'native_clip_writer.dart';

/// Clears a sensitive clip (card number, IBAN) off THIS device's system
/// clipboard when it expires, but only while the clipboard still holds it:
/// anything copied since is the user's and stays.
abstract class SensitiveClipboard {
  static Future<void> clearIfCurrent(String text) async {
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid) {
        await NativeClipWriter.clearIfCurrent(text);
        return;
      }
      final now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == text) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {
      // Best effort: the clip is already gone from history either way.
    }
  }
}
