import 'package:clippy/core/history/clipboard_writer.dart';
import 'package:clippy/core/history/history_item.dart';
import 'package:clippy/core/history/history_store.dart';
import 'package:clippy/core/models/remote_clip.dart';
import 'package:flutter_test/flutter_test.dart';

import '../sync/fakes.dart';

/// Records the last text written, so apply-on-tap can be asserted.
class RecordingClipboardWriter implements ClipboardWriter {
  final List<String> written = [];
  @override
  Future<void> setText(String text) async => written.add(text);
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
}
