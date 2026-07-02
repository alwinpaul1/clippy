import 'package:flutter/services.dart';

/// Bridge to the native Android background clipboard-capture engine (an overlay
/// focus-grab that reads the clipboard when another app copies). All calls are
/// safe no-ops on platforms without the native side.
class CaptureChannel {
  static const _channel = MethodChannel('clippy/capture');

  /// Register a handler invoked with the captured text when the native engine
  /// detects a background copy.
  static void onCaptured(void Function(String text) handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onClip') {
        final text = call.arguments as String?;
        if (text != null && text.isNotEmpty) handler(text);
      }
      return null;
    });
  }

  static Future<bool> hasOverlayPermission() async {
    try {
      return (await _channel.invokeMethod<bool>('hasOverlay')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestOverlayPermission() async {
    try {
      await _channel.invokeMethod('requestOverlay');
    } catch (_) {}
  }

  static Future<void> start() async {
    try {
      await _channel.invokeMethod('start');
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
