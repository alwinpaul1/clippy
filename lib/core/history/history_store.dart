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

  HistoryStore({
    required CryptoBox crypto,
    required ClipboardWriter writer,
    int capacity = 25,
  })  : _crypto = crypto,
        _writer = writer,
        _capacity = capacity;

  /// Decrypt + order newest-first + collapse consecutive duplicate hashes +
  /// cap to [_capacity]. Input order is not trusted; we sort defensively.
  Future<List<HistoryItem>> project(List<RemoteClip> clips) async {
    final sorted = [...clips]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    final items = <HistoryItem>[];
    String? previousHash;
    for (final clip in sorted) {
      if (clip.hash == previousHash) continue; // collapse consecutive dupes
      previousHash = clip.hash;
      items.add(HistoryItem(
        text: await _crypto.open(clip),
        hash: clip.hash,
        source: clip.source,
        timestamp: clip.timestamp,
      ));
      if (items.length >= _capacity) break;
    }
    return items;
  }

  /// Apply-on-tap: put the item's text on the system clipboard. Does not
  /// re-upload (it is already in history).
  Future<void> applyItem(HistoryItem item) => _writer.setText(item.text);
}
