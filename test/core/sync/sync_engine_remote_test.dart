import 'package:clippy/core/models/clip_event.dart';
import 'package:clippy/core/models/remote_clip.dart';
import 'package:clippy/core/sync/sync_action.dart';
import 'package:clippy/core/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeCryptoBox crypto;
  late InMemoryStateStore store;
  final t0 = DateTime.utc(2026, 7, 2, 12, 0, 0);

  RemoteClip remote({
    String text = 'hello',
    String source = 'phoneB',
    DateTime? ts,
  }) =>
      RemoteClip(
          ciphertext: 'enc:$text',
          iv: 'iv',
          hash: 'h:$text',
          source: source,
          timestamp: ts ?? t0);

  SyncEngine build({DateTime? now, InMemoryStateStore? state}) => SyncEngine(
        crypto: crypto,
        state: state ?? store,
        selfDeviceId: 'macA',
        clock: fixedClock(now ?? t0),
      );

  setUp(() {
    crypto = FakeCryptoBox();
    store = InMemoryStateStore();
  });

  test('a fresh remote clip from another device is applied', () async {
    final engine = build();
    final actions = await engine.onRemoteSnapshot(remote(text: 'hi'));
    expect((actions.single as ApplyToClipboard).text, 'hi');
    expect(await store.readLastAppliedHash(), 'h:hi');
  });

  test('a clip whose source is us is ignored', () async {
    final engine = build();
    expect(await engine.onRemoteSnapshot(remote(source: 'macA')), isEmpty);
  });

  test('a clip equal to lastAppliedHash is ignored (reconnect re-delivery)',
      () async {
    final engine = build(state: InMemoryStateStore('h:hello'));
    expect(await engine.onRemoteSnapshot(remote(text: 'hello')), isEmpty);
  });

  test('first snapshot older than 60s -> OfferRestore, clipboard not written',
      () async {
    // now = t0; clip stamped 61s earlier.
    final engine = build(now: t0);
    final stale =
        remote(text: 'old', ts: t0.subtract(const Duration(seconds: 61)));
    final actions = await engine.onRemoteSnapshot(stale);
    expect((actions.single as OfferRestore).text, 'old');
    expect(await store.readLastAppliedHash(), 'h:old',
        reason: 'lastAppliedHash still recorded so it is not offered twice');
  });

  test('first snapshot within 60s is applied (fresh)', () async {
    final engine = build(now: t0);
    final fresh =
        remote(text: 'new', ts: t0.subtract(const Duration(seconds: 30)));
    final actions = await engine.onRemoteSnapshot(fresh);
    expect(actions.single, isA<ApplyToClipboard>());
  });

  test('freshness gate applies only to the FIRST considered snapshot',
      () async {
    final engine = build(now: t0);
    // First snapshot fresh -> applied, gate consumed.
    await engine.onRemoteSnapshot(
        remote(text: 'first', ts: t0.subtract(const Duration(seconds: 10))));
    // Second snapshot is old but arrives mid-session -> still applied.
    final actions = await engine.onRemoteSnapshot(
        remote(text: 'second', ts: t0.subtract(const Duration(seconds: 300))));
    expect((actions.single as ApplyToClipboard).text, 'second');
  });

  test('a self/duplicate first delivery does NOT spend the freshness gate',
      () async {
    final engine = build(now: t0);
    // First delivery is our own echo -> ignored, gate NOT consumed.
    await engine.onRemoteSnapshot(remote(source: 'macA'));
    // Next delivery is a genuinely stale clip -> treated as first considered.
    final actions = await engine.onRemoteSnapshot(
        remote(text: 'stale', ts: t0.subtract(const Duration(seconds: 120))));
    expect(actions.single, isA<OfferRestore>());
  });

  test(
      'applying a remote clip arms one-shot echo suppression for the local watcher',
      () async {
    final engine = build(now: t0);
    await engine.onRemoteSnapshot(remote(text: 'sync'));
    // The clipboard watcher now fires with the applied text -> suppressed.
    final echo =
        await engine.onLocalClip(const ClipEvent(text: 'sync', byteSize: 4));
    expect(echo, isEmpty);
  });
}
