import 'dart:convert';
import 'dart:typed_data';

import '../crypto/crypto_box.dart';
import '../models/remote_clip.dart';
import 'clipboard_writer.dart';
import 'history_item.dart';

/// Turns the encrypted clip list from the backend into the decrypted, ordered,
/// capped, de-duped history the UI shows, and applies a chosen item to the
/// system clipboard on tap (spec §7.1). Pure transform + one side effect, so
/// it is fully unit-testable.
class HistoryStore {
  final CryptoBox _crypto;
  final ClipboardWriter _writer;
  final int _capacity;

  // Decrypted payloads keyed by content hash. Decryption is the load
  // bottleneck — a large pure-Dart AES-GCM (plus a base64 decode for images) —
  // and the relay re-emits the whole snapshot on every change, so a naive
  // project() re-decrypts all 25 items each time a single clip arrives. The
  // hash is HMAC(plaintext), so a cache hit guarantees identical plaintext;
  // clip metadata (source/device/time) is cheap and always taken fresh.
  final Map<String, ({String text, Uint8List? bytes})> _decrypted = {};

  HistoryStore({
    required CryptoBox crypto,
    required ClipboardWriter writer,
    int capacity = 25,
  })  : _crypto = crypto,
        _writer = writer,
        _capacity = capacity;

  /// Decrypt + order newest-first + collapse consecutive duplicate hashes +
  /// cap to [_capacity]. Input order is not trusted; we sort defensively.
  /// Decryption is memoised by content hash, so each clip is decrypted once
  /// across repeated projections rather than on every relay snapshot.
  Future<List<HistoryItem>> project(List<RemoteClip> clips) async {
    final sorted = [...clips]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    // Pass 1: pick the clips to show (collapse consecutive dupes, cap to
    // capacity) — no decryption yet.
    final chosen = <RemoteClip>[];
    String? previousHash;
    for (final clip in sorted) {
      if (clip.hash == previousHash) continue; // collapse consecutive dupes
      previousHash = clip.hash;
      chosen.add(clip);
      if (chosen.length >= _capacity) break;
    }

    // Pass 2: decrypt only the clips we haven't seen before, in ONE batch that
    // the crypto box runs off the UI isolate (so a snapshot of image clips
    // can't freeze the loading spinner). Cached hashes are reused as-is.
    final uncached = [
      for (final c in chosen)
        if (!_decrypted.containsKey(c.hash)) c,
    ];
    if (uncached.isNotEmpty) {
      final plains = await _crypto.openAll(uncached);
      for (var i = 0; i < uncached.length; i++) {
        final clip = uncached[i];
        final text = plains[i];
        Uint8List? bytes;
        if (clip.kind == 'image') {
          try {
            bytes = base64Decode(text);
          } catch (_) {
            bytes = null;
          }
        }
        _decrypted[clip.hash] = (text: text, bytes: bytes);
      }
    }

    final items = [
      for (final clip in chosen)
        HistoryItem(
          text: _decrypted[clip.hash]!.text,
          hash: clip.hash,
          source: clip.source,
          device: clip.device,
          kind: clip.kind,
          mime: clip.mime,
          imageBytes: _decrypted[clip.hash]!.bytes,
          timestamp: clip.timestamp,
        ),
    ];
    // Bound the cache to what's currently shown, so it can't grow past capacity
    // (an image payload each) as clips scroll past the cap.
    final shown = items.map((i) => i.hash).toSet();
    _decrypted.removeWhere((h, _) => !shown.contains(h));
    return items;
  }

  /// Apply-on-tap: put the item's text on the system clipboard. Does not
  /// re-upload (it is already in history).
  Future<void> applyItem(HistoryItem item) => _writer.setText(item.text);
}
