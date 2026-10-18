/// What each image clip contains, for search: the text in a screenshot and,
/// where the platform has a classifier, what a photo shows ("dog", "receipt",
/// "document"). Produced on THIS device by the OS's own vision models (Apple
/// Vision, ML Kit, Windows OCR); never sent anywhere, never written to disk.
/// The relay still only ever sees ciphertext.
///
/// Kept in memory only, keyed by content hash, so an image is analysed once
/// per app run. On the next launch the queue rebuilds it in the background;
/// the history is small (25 clips plus pins), so that costs seconds.
library;

import 'dart:async';
import 'dart:typed_data';

import '../signals/clip_signals.dart';

class ImageInsight {
  /// Recognised text, one line per line in the image ("" when none).
  final String text;

  /// Lower-case content labels, most confident first ("dog", "receipt").
  /// On Windows they come from MobileNetV2 via Windows ML.
  final List<String> labels;

  /// Signals in [text], so "code" finds a screenshot of a verification code.
  final List<ClipSignal> signals;

  ImageInsight({required this.text, required this.labels})
    : signals = detectSignals(text);

  bool get hasText => text.trim().isNotEmpty;
}

/// Analyses one image. Returns null when it failed (retried later) and
/// throws [UnsupportedError] when this platform cannot analyse at all.
typedef ImageAnalyzer = Future<ImageInsight?> Function(Uint8List bytes);

typedef IndexImage = ({String hash, Uint8List bytes});

class ImageIndex {
  ImageIndex({required this.analyze, this.onChange, this.timeout = _timeout});

  final ImageAnalyzer analyze;

  /// Called after each image is analysed, so search results can update.
  final void Function()? onChange;
  final Duration timeout;

  static const _timeout = Duration(seconds: 30);

  /// Attempts per image before it is left alone for this run.
  static const maxAttempts = 2;

  final _byHash = <String, ImageInsight>{};
  final _attempts = <String, int>{};
  final _queue = <IndexImage>[];
  bool _running = false;
  bool _disposed = false;

  /// False once the platform said it cannot analyse images at all.
  bool supported = true;

  ImageInsight? of(String hash) => _byHash[hash];

  /// Images still waiting to be read, including the one in progress.
  int get pending => _queue.length + (_running ? 1 : 0);

  /// Bring the index in line with the current history: forget images that
  /// left it, queue the new ones in the order given (newest first, so the
  /// clip you just copied is searchable first).
  void sync(Iterable<IndexImage> images) {
    if (_disposed || !supported) return;
    final list = images.toList();
    final keep = {for (final i in list) i.hash};
    _byHash.removeWhere((h, _) => !keep.contains(h));
    _attempts.removeWhere((h, _) => !keep.contains(h));
    _queue.removeWhere((i) => !keep.contains(i.hash));
    final queued = {for (final i in _queue) i.hash};
    for (final i in list) {
      if (_byHash.containsKey(i.hash) || queued.contains(i.hash)) continue;
      if ((_attempts[i.hash] ?? 0) >= maxAttempts) continue;
      _queue.add(i);
    }
    unawaited(_drain());
  }

  /// Wait until the queue is empty (tests).
  Future<void> idle() async {
    while (_running || (_queue.isNotEmpty && supported && !_disposed)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void dispose() {
    _disposed = true;
    _queue.clear();
  }

  // One image at a time: the vision models are heavy, and the history list
  // must stay smooth while they run.
  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty && !_disposed && supported) {
        final next = _queue.removeAt(0);
        ImageInsight? result;
        try {
          result = await analyze(next.bytes).timeout(timeout);
        } on UnsupportedError {
          supported = false;
          _queue.clear();
          break;
        } catch (_) {
          result = null; // timeout or native failure: retried on a later sync
        }
        if (_disposed) break;
        if (result == null) {
          _attempts[next.hash] = (_attempts[next.hash] ?? 0) + 1;
          continue;
        }
        _byHash[next.hash] = result;
        onChange?.call();
      }
    } finally {
      _running = false;
    }
    // Pending count reaches zero: let the "reading images" note go away.
    if (!_disposed) onChange?.call();
  }
}
