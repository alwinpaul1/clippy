import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App haptics that actually fire on Samsung. Flutter's HapticFeedback.* maps
/// to View.performHapticFeedback, which One UI gates behind system
/// touch-vibration settings — so on Android we drive the Vibrator directly
/// (MainActivity's clippy/haptics channel). Elsewhere, HapticFeedback.
abstract class Haptics {
  static const _channel = MethodChannel('clippy/haptics');

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Short, light: threshold crossings, selection.
  static Future<void> tick() => _fire('tick', HapticFeedback.selectionClick);

  /// Firm: deletes, clear-all confirms.
  static Future<void> thump() => _fire('thump', HapticFeedback.heavyImpact);

  static Future<void> _fire(
    String method,
    Future<void> Function() fallback,
  ) async {
    if (_isAndroid) {
      try {
        await _channel.invokeMethod<void>(method);
        return;
      } catch (_) {
        // Channel missing (tests, odd embeddings) — fall through.
      }
    }
    await fallback();
  }
}
