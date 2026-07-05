import 'package:clippy/core/crypto/crypto_box.dart';
import 'package:clippy/core/history/clipboard_writer.dart';
import 'package:clippy/core/history/history_item.dart';
import 'package:clippy/core/history/history_store.dart';
import 'package:clippy/core/models/encrypted_clip.dart';
import 'package:clippy/core/models/remote_clip.dart';
import 'package:flutter_test/flutter_test.dart';

import '../sync/fakes.dart';

/// Records the last text written, so apply-on-tap can be asserted.
class RecordingClipboardWriter implements ClipboardWriter {
  final List<String> written = [];
  @override
  Future<void> setText(String text) async => written.add(text);
}

/// Wraps [FakeCryptoBox] and counts decrypted clips — to assert decryption is
/// memoised across projections. project() now decrypts via openAll (one batch,
/// off the UI isolate in production), so count per clip there.
class CountingCryptoBox implements CryptoBox {
  final FakeCryptoBox _inner = FakeCryptoBox();
  int opens = 0;
  @override
  bool get isPaired => _inner.isPaired;
  @override
  Future<String> fingerprint(String plaintext) => _inner.fingerprint(plaintext);
  @override
  Future<EncryptedClip> seal(String plaintext, {required String source}) =>
      _inner.seal(plaintext, source: source);
  @override
  Future<String> open(RemoteClip clip) {
    opens++;
    return _inner.open(clip);
  }

  @override
  Future<List<String>> openAll(List<RemoteClip> clips) {
    opens += clips.length;
    return _inner.openAll(clips);
  }
}

void main() {
  late FakeCryptoBox crypto;
  late RecordingClipboardWriter writer;
  final base = DateTime.utc(2026, 7, 2, 12, 0, 0);

  RemoteClip clip(String text, {required int agoSeconds, String source = 'x'}) =>
      RemoteClip(
        ciphertext: 'enc:$text',
        iv: 'iv',
        hash: 'h:$text',
        source: source,
        timestamp: base.subtract(Duration(seconds: agoSeconds)),
      );

  setUp(() {
    crypto = FakeCryptoBox();
    writer = RecordingClipboardWriter();
  });

  test('project decrypts and orders newest-first', () async {
    final store = HistoryStore(crypto: crypto, writer: writer);
    final items = await store.project([
      clip('older', agoSeconds: 100),
      clip('newest', agoSeconds: 1),
      clip('middle', agoSeconds: 50),
    ]);
    expect(items.map((i) => i.text).toList(), ['newest', 'middle', 'older']);
  });

  test('project caps to capacity (newest N kept)', () async {
    final store = HistoryStore(crypto: crypto, writer: writer, capacity: 2);
    final items = await store.project([
      clip('a', agoSeconds: 3),
      clip('b', agoSeconds: 2),
      clip('c', agoSeconds: 1),
    ]);
    expect(items.map((i) => i.text).toList(), ['c', 'b']);
  });

  test('consecutive identical hashes collapse to one', () async {
    final store = HistoryStore(crypto: crypto, writer: writer);
    final items = await store.project([
      clip('dup', agoSeconds: 1),
      clip('dup', agoSeconds: 2),
      clip('other', agoSeconds: 3),
    ]);
    expect(items.map((i) => i.text).toList(), ['dup', 'other']);
  });

  test('non-consecutive identical hashes are both kept', () async {
    final store = HistoryStore(crypto: crypto, writer: writer);
    final items = await store.project([
      clip('a', agoSeconds: 1),
      clip('b', agoSeconds: 2),
      clip('a', agoSeconds: 3),
    ]);
    expect(items.map((i) => i.text).toList(), ['a', 'b', 'a']);
  });

  test('empty input yields empty history', () async {
    final store = HistoryStore(crypto: crypto, writer: writer);
    expect(await store.project([]), isEmpty);
  });

  test('applyItem writes the item text to the clipboard (no re-upload)',
      () async {
    final store = HistoryStore(crypto: crypto, writer: writer);
    final item = HistoryItem(
        text: 'pasted', hash: 'h:pasted', source: 'phoneB', timestamp: base);
    await store.applyItem(item);
    expect(writer.written, ['pasted']);
  });

  test('HistoryItem carries hash/source/timestamp from the clip', () async {
    final store = HistoryStore(crypto: crypto, writer: writer);
    final items = await store.project([clip('t', agoSeconds: 5, source: 'macA')]);
    final only = items.single;
    expect(only.text, 't');
    expect(only.hash, 'h:t');
    expect(only.source, 'macA');
    expect(only.timestamp, base.subtract(const Duration(seconds: 5)));
  });

  test('project memoises decryption — re-projection does not re-decrypt',
      () async {
    final counting = CountingCryptoBox();
    final store = HistoryStore(crypto: counting, writer: writer);
    final clips = [clip('a', agoSeconds: 1), clip('b', agoSeconds: 2)];
    expect((await store.project(clips)).map((i) => i.text).toList(), ['a', 'b']);
    expect(counting.opens, 2);
    // The relay re-emits the whole snapshot on every change — the second
    // projection must serve both items from cache.
    expect((await store.project(clips)).map((i) => i.text).toList(), ['a', 'b']);
    expect(counting.opens, 2); // no new decrypts
  });

  test('re-projection reuses cached plaintext but takes metadata fresh',
      () async {
    final counting = CountingCryptoBox();
    final store = HistoryStore(crypto: counting, writer: writer);
    await store.project([clip('a', agoSeconds: 1, source: 'devX')]);
    expect(counting.opens, 1);
    // Same content (hash 'h:a'), different source → cached decrypt, fresh meta.
    final items = await store.project([clip('a', agoSeconds: 1, source: 'devY')]);
    expect(counting.opens, 1);
    expect(items.single.source, 'devY');
  });
}
