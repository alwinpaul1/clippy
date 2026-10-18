import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'clip_signals.dart';

/// How long a sensitive clip (card number, IBAN) lives before it is removed
/// from the shared history and from this device's clipboard. A per-device
/// setting; whichever device's timer fires first deletes it for the room.
abstract class SensitiveTtl {
  static const prefsKey = 'clippy.sensitive.ttlMin';
  static const choices = [1, 5, 15];
  static const defaultMinutes = 5;

  static Future<Duration> read() async {
    final prefs = await SharedPreferences.getInstance();
    // The background isolate keeps its own prefs cache; pick up a change
    // made in Settings.
    await prefs.reload();
    final m = prefs.getInt(prefsKey) ?? defaultMinutes;
    return Duration(minutes: choices.contains(m) ? m : defaultMinutes);
  }

  static Future<void> write(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(prefsKey, minutes);
  }
}

/// One clip as the sweeper sees it.
typedef SweepClip = ({
  String hash,
  String text,
  bool isImage,
  DateTime timestamp,
});

/// Signals per clip, cached by content hash: detection runs once per clip,
/// not once per frame.
class SignalCache {
  final _byHash = <String, List<ClipSignal>>{};

  List<ClipSignal> of(String hash, String text, {bool isImage = false}) {
    if (isImage) return const [];
    return _byHash.putIfAbsent(hash, () => detectSignals(text));
  }

  bool isSensitive(String hash, String text, {bool isImage = false}) =>
      hasSensitive(of(hash, text, isImage: isImage));

  /// Forget clips that left the history.
  void retain(Iterable<String> hashes) {
    final keep = hashes.toSet();
    _byHash.removeWhere((h, _) => !keep.contains(h));
  }
}

/// Deletes expired sensitive clips and wipes them off the clipboard. Runs in
/// the app (all platforms) AND in Android's background service, so a card
/// number expires even while the Clippy UI is closed. Running twice is
/// harmless: a delete of an already-deleted hash is a no-op on the relay.
class SensitiveSweeper {
  SensitiveSweeper({
    required this.clips,
    required this.delete,
    required this.clearClipboard,
    required this.signals,
    Future<Duration> Function()? ttl,
    DateTime Function()? clock,
  }) : _ttl = ttl ?? SensitiveTtl.read,
       _clock = clock ?? DateTime.now;

  final List<SweepClip> Function() clips;
  final Future<void> Function(List<String> hashes) delete;
  final Future<void> Function(String text) clearClipboard;
  final SignalCache signals;
  final Future<Duration> Function() _ttl;
  final DateTime Function() _clock;

  final _done = <String>{};
  Timer? _timer;
  bool _running = false;

  static const interval = Duration(seconds: 15);

  void start() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(sweep()));
    unawaited(sweep());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass. Returns the hashes it removed.
  Future<List<String>> sweep() async {
    if (_running) return const [];
    _running = true;
    try {
      final ttl = await _ttl();
      final now = _clock();
      final doomed = <SweepClip>[];
      for (final c in clips()) {
        if (c.isImage || _done.contains(c.hash)) continue;
        if (now.difference(c.timestamp) < ttl) continue;
        if (signals.isSensitive(c.hash, c.text)) doomed.add(c);
      }
      if (doomed.isEmpty) return const [];
      final hashes = [for (final c in doomed) c.hash];
      _done.addAll(hashes);
      await delete(hashes);
      for (final c in doomed) {
        await clearClipboard(c.text);
      }
      return hashes;
    } finally {
      _running = false;
    }
  }

  /// Time left before [timestamp]'s clip is cleared, never negative.
  static Duration remaining(DateTime timestamp, Duration ttl, {DateTime? now}) {
    final left = ttl - (now ?? DateTime.now()).difference(timestamp);
    return left.isNegative ? Duration.zero : left;
  }
}
