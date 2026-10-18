import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's native clipboard writer (`ClipWriter.kt`), registered on BOTH the
/// UI engine and the headless foreground-service engine. Every incoming clip
/// goes through it on Android so that:
///  - images are pasteable from either isolate (super_clipboard's own image
///    write serves an empty file to paste targets), and
///  - the accessibility service can tell our write from a user copy and skip
///    the read-back that flashed the screen on every incoming clip.
///
/// Each call returns false when the native side is unavailable (not Android,
/// or no handler on this engine) so the caller falls back to its old path.
abstract class NativeClipWriter {
  static const _channel = MethodChannel('clippy/clipwrite');

  /// Host-test override for the platform gate.
  @visibleForTesting
  static bool? debugIsAndroid;

  static bool get _isAndroid => debugIsAndroid ?? (!kIsWeb && Platform.isAndroid);

  /// [sensitive] marks the clip so Android 13+ hides it in its own clipboard
  /// preview (card numbers, IBANs).
  static Future<bool> writeText(String text, {bool sensitive = false}) =>
      _invoke('writeText', {'text': text, 'sensitive': sensitive});

  /// Wipe the clipboard if it still holds [text], i.e. nothing newer was
  /// copied since. Android cannot read the clipboard from the background, so
  /// the native side tracks what it last wrote or saw copied.
  static Future<bool> clearIfCurrent(String text) =>
      _invoke('clearIfCurrent', {'text': text});

  static Future<bool> writeImage(Uint8List bytes, String ext) =>
      _invoke('writeImage', {'bytes': bytes, 'ext': ext});

  static Future<bool> _invoke(String method, Map<String, Object> args) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } catch (_) {
      return false;
    }
  }
}
