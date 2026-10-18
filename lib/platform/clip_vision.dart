import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/vision/image_index.dart';
import '../core/vision/imagenet_groups.dart';

/// The native side of image search ("clippy/vision"): ClipVision in
/// MainFlutterWindow.swift (Apple Vision), ClipVision.kt (ML Kit, bundled
/// models) and windows/runner/clip_vision.cpp (Windows.Media.Ocr plus
/// MobileNetV2 through Windows ML).
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
      final labels = [
        for (final l in (out['labels'] as List?) ?? const [])
          if (l is String && l.trim().isNotEmpty) l.trim().toLowerCase(),
      ];
      // Windows names ImageNet classes ("kelpie"); add the everyday word.
      final classes = (out['imagenet'] as List?)?.whereType<int>().toList();
      if (classes != null && classes.length == labels.length) {
        final expanded = <String>[];
        for (var k = 0; k < labels.length; k++) {
          for (final w in imagenetLabels(labels[k], classes[k])) {
            if (!expanded.contains(w)) expanded.add(w);
          }
        }
        labels
          ..clear()
          ..addAll(expanded);
      }
      return ImageInsight(text: (out['text'] as String?) ?? '', labels: labels);
    } on MissingPluginException {
      throw UnsupportedError('clippy/vision is not registered');
    } on PlatformException catch (e) {
      debugPrint('Image analysis failed: ${e.code}');
      return null;
    }
  }
}
