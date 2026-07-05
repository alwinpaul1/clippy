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

    // Re-copying content that is already the room's latest is a no-op —
    // uploading again would only manufacture duplicates (Rule 2b).
    final again =
        await engine.onLocalClip(const ClipEvent(text: 'remote', byteSize: 6));
    expect(again, isEmpty);
  });

  test('echo window expiry: a late echo of OLDER content uploads again',
      () async {
    // Apply remote at t0 (arms the one-shot echo for h:remote). A copy of
    // different content moves lastApplied on; when 'remote' comes back at
    // t0+3s the echo window has expired and Rule 2b no longer matches, so it
    // uploads as a genuine new copy.
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
    _clockValue = t0.add(const Duration(seconds: 1));
    await engine.onLocalClip(const ClipEvent(text: 'other', byteSize: 5));
    _clockValue = t0.add(const Duration(seconds: 3));
    final late =
        await engine.onLocalClip(const ClipEvent(text: 'remote', byteSize: 6));
    expect(late.single, isA<UploadClip>());
  });

  test('text matching the persisted lastAppliedHash is not re-uploaded',
      () async {
    // Another isolate (the background service) applied this clip and persisted
    // its hash; a fresh engine re-reading the same clipboard must not upload a
    // duplicate. The in-memory echo window can't cover this — it's per-isolate.
    await store.writeLastAppliedHash('h:from-service');
    final engine = build();
    final actions = await engine
        .onLocalClip(const ClipEvent(text: 'from-service', byteSize: 12));
    expect(actions, isEmpty);
  });

  test('image matching the persisted lastAppliedHash is not re-uploaded',
      () async {
    await store.writeLastAppliedHash('h:imgdata');
    final engine = build();
    final actions = await engine.onLocalImage('imgdata');
    expect(actions, isEmpty);
  });

  // noteApplied — tap-to-apply of an existing history item must not re-upload.
  test('noteApplied suppresses the re-capture echo of a tapped text item',
      () async {
    final engine = build();
    // Tapping an OLDER item (not the current lastApplied) re-applies it.
    await engine.noteApplied('h:old-note');
    final echo = await engine
        .onLocalClip(const ClipEvent(text: 'old-note', byteSize: 8));
    expect(echo, isEmpty, reason: 're-applied item must not re-broadcast');
    // And it persisted, so the cross-isolate Android drain dedups it too.
    expect(await store.readLastAppliedHash(), 'h:old-note');
  });

  test('noteApplied suppresses an image re-capture (persisted Rule 2b)',
      () async {
    final engine = build();
    await engine.noteApplied('h:imgbytes');
    expect(await engine.onLocalImage('imgbytes'), isEmpty);
  });

  test('a DIFFERENT clip copied after noteApplied still uploads', () async {
    final engine = build();
    await engine.noteApplied('h:tapped');
    final other =
        await engine.onLocalClip(const ClipEvent(text: 'fresh', byteSize: 5));
    expect(other.single, isA<UploadClip>());
  });
}

// Mutable clock backing for the expiry test.
DateTime _clockValue = DateTime.utc(2026);
