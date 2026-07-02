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

  SyncEngine build({DateTime? now}) => SyncEngine(
        crypto: crypto,
        state: store,
        selfDeviceId: 'macA',
        clock: fixedClock(now ?? t0),
      );

  setUp(() {
    crypto = FakeCryptoBox();
    store = InMemoryStateStore();
  });

  test('a fresh text copy produces an UploadClip with our source and hash',
      () async {
    final engine = build();
    final actions =
        await engine.onLocalClip(const ClipEvent(text: 'hello', byteSize: 5));
    expect(actions, hasLength(1));
    final a = actions.single as UploadClip;
    expect(a.clip.source, 'macA');
    expect(a.clip.hash, 'h:hello');
    expect(a.clip.ciphertext, 'enc:hello');
    expect(await store.readLastAppliedHash(), 'h:hello');
  });

  test('non-text clip is ignored', () async {
    final engine = build();
    expect(await engine.onLocalClip(const ClipEvent(text: null)), isEmpty);
  });

  test('concealed clip is ignored (password manager)', () async {
    final engine = build();
    expect(
      await engine.onLocalClip(
          const ClipEvent(text: 'secret', isConcealed: true, byteSize: 6)),
      isEmpty,
    );
  });

  test('oversize clip is skipped, not truncated', () async {
    final engine = build();
    expect(
      await engine.onLocalClip(ClipEvent(text: 'x', byteSize: 102401)),
      isEmpty,
    );
  });

  test('echo of a just-applied remote clip within 2s is suppressed once',
      () async {
    // Apply a remote clip at t0 so expectedEchoHash = h:remote, expiry t0+2s.
    final engine = build(now: t0);
    final remote = RemoteClip(
        ciphertext: 'enc:remote',
        iv: 'iv',
        hash: 'h:remote',
        source: 'phoneB',
        timestamp: t0);
    final applied = await engine.onRemoteSnapshot(remote);
    expect(applied.single, isA<ApplyToClipboard>());

    // The watcher now fires with the identical text at t0+1s -> suppressed.
    final echo =
        await engine.onLocalClip(const ClipEvent(text: 'remote', byteSize: 6));
    expect(echo, isEmpty, reason: 'echo must not re-upload');
  });

  test('re-copying the same text LATER (after echo consumed) uploads again',
      () async {
    final engine = build(now: t0);
    final remote = RemoteClip(
        ciphertext: 'enc:remote',
        iv: 'iv',
        hash: 'h:remote',
        source: 'phoneB',
        timestamp: t0);
    await engine.onRemoteSnapshot(remote); // sets echo
    await engine
        .onLocalClip(const ClipEvent(text: 'remote', byteSize: 6)); // consumes

    // User copies 'remote' again intentionally -> must upload.
    final again =
        await engine.onLocalClip(const ClipEvent(text: 'remote', byteSize: 6));
    expect(again.single, isA<UploadClip>());
  });

  test('echo guard does not fire after the 2s window expires', () async {
    // Apply remote at t0; local event arrives at t0+3s -> window expired -> upload.
    final engine = SyncEngine(
        crypto: crypto,
        state: store,
        selfDeviceId: 'macA',
        clock: () => _clockValue);
    _clockValue = t0;
    final remote = RemoteClip(
        ciphertext: 'enc:remote',
        iv: 'iv',
        hash: 'h:remote',
        source: 'phoneB',
        timestamp: t0);
    await engine.onRemoteSnapshot(remote);
    _clockValue = t0.add(const Duration(seconds: 3));
    final late =
        await engine.onLocalClip(const ClipEvent(text: 'remote', byteSize: 6));
    expect(late.single, isA<UploadClip>());
  });
}

// Mutable clock backing for the expiry test.
DateTime _clockValue = DateTime.utc(2026);
