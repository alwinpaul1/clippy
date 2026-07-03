import 'package:flutter/services.dart';

/// Receives text OR images sent to Clippy via Android's "Send to Clippy" entry
/// points (text-selection popup + Share sheet). No special permissions — the
/// user picks "Clippy" and it syncs. On desktop the native channel is absent,
/// so the calls no-op.
abstract class ShareChannel {
  static const _channel = MethodChannel('clippy/share');

  /// Register handlers for shares that arrive while the app is running. Call
  /// with no handlers to detach (e.g. on dispose).
  static void listen({
    void Function(String text)? onText,
    void Function(Uint8List bytes, String mime)? onImage,
  }) {
    if (onText == null && onImage == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShared') _dispatch(call.arguments, onText, onImage);
      return null;
    });
  }

  /// Deliver the text/image Clippy was cold-launched with (if any).
  static Future<void> initial({
    void Function(String text)? onText,
    void Function(Uint8List bytes, String mime)? onImage,
  }) async {
    try {
      final arg = await _channel.invokeMethod<dynamic>('getInitialText');
      _dispatch(arg, onText, onImage);
    } on MissingPluginException {
      // Desktop / no native channel.
    } on PlatformException {
      // Ignore.
    }
  }

  /// Start the Android screenshot auto-sync: new screenshots arrive through
  /// the [listen] onImage handler like shared images. Prompts for photo access
  /// on first call. Returns the access level:
  ///  - 'granted': full access — screenshots will sync.
  ///  - 'partial': Android 14+ "Select photos" — screenshots WON'T sync;
  ///    the user must grant full access (see [openPhotoSettings]).
  ///  - 'denied' / 'unavailable': no sync.
  static Future<String> startScreenshotWatch() async {
    try {
      return await _channel.invokeMethod<String>('startScreenshotWatch') ??
          'denied';
    } on MissingPluginException {
      return 'unavailable'; // Desktop / no native channel.
    } on PlatformException {
      return 'denied';
    }
  }

  /// Open Clippy's app-settings page so the user can switch photo access from
  /// "Select photos" to "Allow all" (partial can't be upgraded in-app).
  static Future<void> openPhotoSettings() async {
    try {
      await _channel.invokeMethod<void>('openPhotoSettings');
    } on MissingPluginException {
      // Desktop / no native channel.
    } on PlatformException {
      // Ignore.
    }
  }

  static void _dispatch(
    dynamic arg,
    void Function(String)? onText,
    void Function(Uint8List, String)? onImage,
  ) {
    if (arg is String) {
      if (arg.isNotEmpty) onText?.call(arg);
    } else if (arg is Map) {
      final bytes = arg['bytes'];
      final mime = (arg['mime'] as String?) ?? 'image/*';
      if (bytes is Uint8List && onImage != null) onImage(bytes, mime);
    }
  }
}
