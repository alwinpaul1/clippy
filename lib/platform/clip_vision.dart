import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/vision/image_index.dart';

/// The native side of image search ("clippy/vision"): ClipVision in
/// MainFlutterWindow.swift (Apple Vision), ClipVision.kt (ML Kit, bundled
/// models) and windows/runner/clip_vision.cpp (Windows.Media.Ocr).
abstract class ClipVision {
  static const _channel = MethodChannel('clippy/vision');

  static bool get platformSupported =>
      !kIsWeb && (Platform.isMacOS || Platform.isAndroid || Platform.isWindows);

  static Future<ImageInsight?> analyze(Uint8List bytes) async {
    if (!platformSupported) throw UnsupportedError('no image analysis here');
    try {
      final out = await _channel.invokeMapMethod<String, Object?>('analyze', {
        'bytes': bytes,
      });
      if (out == null) return null;
      return ImageInsight(
        text: (out['text'] as String?) ?? '',
        labels: [
          for (final l in (out['labels'] as List?) ?? const [])
            if (l is String && l.trim().isNotEmpty) l.trim().toLowerCase(),
        ],
      );
    } on MissingPluginException {
      throw UnsupportedError('clippy/vision is not registered');
    } on PlatformException catch (e) {
      debugPrint('Image analysis failed: ${e.code}');
      return null;
    }
  }
}
