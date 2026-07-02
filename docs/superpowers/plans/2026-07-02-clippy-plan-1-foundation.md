# Clippy — Plan 1: Foundation (Core Sync Engine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure-Dart correctness core of Clippy — the `SyncEngine` state machine (spec §7) plus its models and injected interfaces — fully unit-tested, with zero cloud, device, or code-signing dependencies.

**Architecture:** A single Flutter project targeting macOS + Android. This plan builds only `lib/core/**` — platform-agnostic Dart. The `SyncEngine` consumes local clipboard events and remote Firestore snapshots and *emits actions* (`UploadClip`, `ApplyToClipboard`, `OfferRestore`) rather than performing side effects, so every branch of the echo-guard / freshness / dedup logic is deterministically testable with fakes. Encryption and persistence are behind the `CryptoBox` and `StateStore` interfaces; this plan ships test-double implementations only. Real AES-GCM, Firebase, and the platform apps come in Plans 2–4.

**Tech Stack:** Flutter (Dart 3), `flutter_test`. No third-party runtime dependencies in this plan.

## Global Constraints

Copied verbatim from the spec; every task's requirements implicitly include these.

- **Platforms:** one Flutter codebase, targets **macOS + Android** only (v1).
- **Content:** **text only** in v1; non-text clip events are ignored.
- **Size cap:** **100 KB plaintext = 102400 bytes**; a clip whose UTF-8 byte size exceeds this is skipped (never truncated). (Firestore rule caps ciphertext at 150000; enforced in Plan 3.)
- **Echo-guard fingerprint:** `h = HMAC(key, plaintext)` via the injected `CryptoBox`. **Never store or compute a plaintext hash oracle** in the core; the engine only ever holds fingerprints returned by `CryptoBox`.
- **Ordering/freshness clock:** ordering uses the server timestamp, surfaced to the engine as `RemoteClip.timestamp` (a resolved `DateTime`). The engine's own "now" is an **injected clock** (`DateTime Function()`), never `DateTime.now()` inline, so tests are deterministic.
- **Freshness window:** **60 seconds, applied only to the first considered snapshot of a session.**
- **Echo window:** **2 seconds, one-shot** (consumed by the next matching local event).
- **`lastAppliedHash`:** **persisted** across restarts via `StateStore`.
- **Device id:** `selfDeviceId` is injected (random per-install id generated in a later plan).

---

## Plan Sequence (context)

This is Plan 1 of 4. Later plans depend on the interfaces produced here:
- **Plan 2** — real `AesGcmCryptoBox` (implements `CryptoBox`), Keychain/Keystore key storage, `AuthController`, `ClipStore` (implements the Firestore side), security rules, App Check.
- **Plan 3** — macOS app: `ClipboardPort` (NSPasteboard), menu-bar shell, pairing QR display; wires `SyncEngine` to a real `StateStore` (shared_preferences).
- **Plan 4** — Android app: tiered capture engine, foreground service, pairing scan, OEM onboarding.

---

## File Structure

Created by this plan:

```
lib/
  core/
    models/
      clip_event.dart        # ClipEvent — a local clipboard change observed by a platform
      encrypted_clip.dart    # EncryptedClip — sealed payload to upload (no timestamp; server adds it)
      remote_clip.dart       # RemoteClip — a decrypted-lazily snapshot delivered from Firestore
    crypto/
      crypto_box.dart        # CryptoBox (abstract) — seal / open / fingerprint / isPaired
    sync/
      sync_action.dart       # SyncAction sealed type: UploadClip | ApplyToClipboard | OfferRestore
      state_store.dart       # StateStore (abstract) — persist lastAppliedHash
      sync_engine.dart       # SyncEngine — the §7 state machine
test/
  core/
    models/
      clip_event_test.dart
      encrypted_clip_test.dart
      remote_clip_test.dart
    sync/
      fakes.dart             # FakeCryptoBox, InMemoryStateStore, fixedClock helper
      sync_engine_local_test.dart
      sync_engine_remote_test.dart
```

`lib/main.dart` and `test/widget_test.dart` from `flutter create` are left untouched except that the default `test/widget_test.dart` is deleted in Task 1 (we do not maintain the counter-app test). `main.dart` is replaced in Plan 3.

---

### Task 1: Scaffold the Flutter project and establish a green test baseline

**Files:**
- Create (via tooling): `pubspec.yaml`, `android/`, `macos/`, `lib/main.dart`, `analysis_options.yaml`
- Delete: `test/widget_test.dart` (default counter-app test)
- Create: `test/smoke_test.dart`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a working Flutter project where `flutter test` passes; `lib/core/` directory tree exists.

- [ ] **Step 1: Verify Flutter is installed**

Run: `flutter --version`
Expected: prints a Flutter 3.x / Dart 3.x version. If "command not found", stop and install Flutter first.

- [ ] **Step 2: Scaffold the project in-place**

The repo root already contains `.git/`, `docs/`, and `.gitignore`. Scaffold into it:

Run: `flutter create --project-name clippy --org dev.alwin --platforms=macos,android .`
Expected: creates `pubspec.yaml`, `lib/main.dart`, `android/`, `macos/`, `test/widget_test.dart`. (The `--org` value sets the bundle/app id prefix `dev.alwin.clippy`; it can be changed later before Firebase setup.)

- [ ] **Step 3: Create the core directory tree**

Run:
```bash
mkdir -p lib/core/models lib/core/crypto lib/core/sync test/core/models test/core/sync
```
Expected: directories created (empty).

- [ ] **Step 4: Remove the default counter-app test and add a smoke test**

Run: `rm test/widget_test.dart`

Create `test/smoke_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('test harness runs', () {
    expect(1 + 1, 2);
  });
}
```

- [ ] **Step 5: Run the test suite to verify green baseline**

Run: `flutter test`
Expected: PASS — `All tests passed!` (1 test).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: scaffold Flutter project (macos+android) with green test baseline"
```

---

### Task 2: Core models — ClipEvent, EncryptedClip, RemoteClip

**Files:**
- Create: `lib/core/models/clip_event.dart`
- Create: `lib/core/models/encrypted_clip.dart`
- Create: `lib/core/models/remote_clip.dart`
- Test: `test/core/models/clip_event_test.dart`, `test/core/models/encrypted_clip_test.dart`, `test/core/models/remote_clip_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ClipEvent({String? text, bool isConcealed, int byteSize})` with `bool get isText`.
  - `EncryptedClip({required String ciphertext, required String iv, required String hash, required String source})` with `Map<String, dynamic> toMap()` and `factory EncryptedClip.fromMap(Map<String, dynamic>)`; value equality.
  - `RemoteClip({required String ciphertext, required String iv, required String hash, required String source, required DateTime timestamp})` with `factory RemoteClip.fromMap(Map<String, dynamic> map, {required DateTime timestamp})`; value equality.

- [ ] **Step 1: Write the failing tests**

Create `test/core/models/clip_event_test.dart`:
```dart
import 'package:clippy/core/models/clip_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('isText is true when text is non-null', () {
    expect(const ClipEvent(text: 'hi', byteSize: 2).isText, isTrue);
  });

  test('isText is false when text is null (non-text clipboard)', () {
    expect(const ClipEvent(text: null).isText, isFalse);
  });

  test('defaults: not concealed, zero byteSize', () {
    const e = ClipEvent(text: 'x', byteSize: 1);
    expect(e.isConcealed, isFalse);
  });
}
```

Create `test/core/models/encrypted_clip_test.dart`:
```dart
import 'package:clippy/core/models/encrypted_clip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const clip = EncryptedClip(
    ciphertext: 'ct', iv: 'iv', hash: 'h', source: 'devA');

  test('toMap contains all fields (no timestamp — server adds it)', () {
    final m = clip.toMap();
    expect(m, {'ciphertext': 'ct', 'iv': 'iv', 'hash': 'h', 'source': 'devA'});
    expect(m.containsKey('timestamp'), isFalse);
  });

  test('fromMap round-trips via value equality', () {
    expect(EncryptedClip.fromMap(clip.toMap()), clip);
  });
}
```

Create `test/core/models/remote_clip_test.dart`:
```dart
import 'package:clippy/core/models/remote_clip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ts = DateTime.utc(2026, 7, 2, 12, 0, 0);

  test('fromMap builds a RemoteClip with the injected resolved timestamp', () {
    final c = RemoteClip.fromMap(
      {'ciphertext': 'ct', 'iv': 'iv', 'hash': 'h', 'source': 'devA'},
      timestamp: ts,
    );
    expect(c.ciphertext, 'ct');
    expect(c.iv, 'iv');
    expect(c.hash, 'h');
    expect(c.source, 'devA');
    expect(c.timestamp, ts);
  });

  test('value equality', () {
    final a = RemoteClip(
      ciphertext: 'ct', iv: 'iv', hash: 'h', source: 'devA', timestamp: ts);
    final b = RemoteClip(
      ciphertext: 'ct', iv: 'iv', hash: 'h', source: 'devA', timestamp: ts);
    expect(a, b);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/core/models/`
Expected: FAIL — `Error: Couldn't resolve the package 'clippy'` targets or "Target of URI doesn't exist" for the model files (not yet created).

- [ ] **Step 3: Write the models**

Create `lib/core/models/clip_event.dart`:
```dart
import 'package:meta/meta.dart';

/// A change observed on the local system clipboard, reported by a platform's
/// ClipboardPort. `text` is null for non-text clipboard content.
@immutable
class ClipEvent {
  final String? text;
  final bool isConcealed;

  /// UTF-8 byte length of [text]; 0 when [text] is null.
  final int byteSize;

  const ClipEvent({this.text, this.isConcealed = false, this.byteSize = 0});

  bool get isText => text != null;
}
```

Create `lib/core/models/encrypted_clip.dart`:
```dart
import 'package:meta/meta.dart';

/// A sealed clip ready to upload. No timestamp: the server stamps it on write
/// (FieldValue.serverTimestamp) so ordering never uses a device clock.
@immutable
class EncryptedClip {
  final String ciphertext;
  final String iv;
  final String hash;
  final String source;

  const EncryptedClip({
    required this.ciphertext,
    required this.iv,
    required this.hash,
    required this.source,
  });

  Map<String, dynamic> toMap() => {
        'ciphertext': ciphertext,
        'iv': iv,
        'hash': hash,
        'source': source,
      };

  factory EncryptedClip.fromMap(Map<String, dynamic> map) => EncryptedClip(
        ciphertext: map['ciphertext'] as String,
        iv: map['iv'] as String,
        hash: map['hash'] as String,
        source: map['source'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is EncryptedClip &&
      other.ciphertext == ciphertext &&
      other.iv == iv &&
      other.hash == hash &&
      other.source == source;

  @override
  int get hashCode => Object.hash(ciphertext, iv, hash, source);
}
```

Create `lib/core/models/remote_clip.dart`:
```dart
import 'package:meta/meta.dart';

/// A clip delivered from Firestore. [timestamp] is the resolved server
/// timestamp (the ClipStore converts Firestore's Timestamp to a DateTime).
@immutable
class RemoteClip {
  final String ciphertext;
  final String iv;
  final String hash;
  final String source;
  final DateTime timestamp;

  const RemoteClip({
    required this.ciphertext,
    required this.iv,
    required this.hash,
    required this.source,
    required this.timestamp,
  });

  factory RemoteClip.fromMap(
    Map<String, dynamic> map, {
    required DateTime timestamp,
  }) =>
      RemoteClip(
        ciphertext: map['ciphertext'] as String,
        iv: map['iv'] as String,
        hash: map['hash'] as String,
        source: map['source'] as String,
        timestamp: timestamp,
      );

  @override
  bool operator ==(Object other) =>
      other is RemoteClip &&
      other.ciphertext == ciphertext &&
      other.iv == iv &&
      other.hash == hash &&
      other.source == source &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(ciphertext, iv, hash, source, timestamp);
}
```

- [ ] **Step 4: Ensure `meta` is available**

`meta` ships transitively with Flutter, but declare it explicitly for clarity.
Run: `flutter pub add meta`
Expected: adds `meta` to `pubspec.yaml` dependencies; `pub get` succeeds.

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/core/models/`
Expected: PASS — all model tests green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): add ClipEvent, EncryptedClip, RemoteClip models"
```

---

### Task 3: Interfaces and test doubles — CryptoBox, StateStore, SyncAction, fakes

**Files:**
- Create: `lib/core/crypto/crypto_box.dart`
- Create: `lib/core/sync/state_store.dart`
- Create: `lib/core/sync/sync_action.dart`
- Create: `test/core/sync/fakes.dart`
- Test: assertions on the fakes live in `test/core/sync/fakes.dart`'s own `main()`.

**Interfaces:**
- Consumes: `EncryptedClip`, `RemoteClip` (Task 2).
- Produces:
  - `abstract class CryptoBox` with `Future<EncryptedClip> seal(String plaintext, {required String source})`, `Future<String> open(RemoteClip clip)`, `Future<String> fingerprint(String plaintext)`, `bool get isPaired`.
  - `abstract class StateStore` with `Future<String?> readLastAppliedHash()`, `Future<void> writeLastAppliedHash(String hash)`.
  - sealed `SyncAction` = `UploadClip(EncryptedClip clip)` | `ApplyToClipboard(String text)` | `OfferRestore(String text)`.
  - `FakeCryptoBox` (deterministic: `fingerprint(x) => 'h:$x'`, `seal(x, source) => EncryptedClip(ciphertext:'enc:$x', iv:'iv', hash:'h:$x', source:source)`, `open(clip) => clip.ciphertext.substring(4)`), `InMemoryStateStore`.

- [ ] **Step 1: Write the failing test for the fakes' contract**

Create `test/core/sync/fakes.dart`:
```dart
import 'package:clippy/core/crypto/crypto_box.dart';
import 'package:clippy/core/models/encrypted_clip.dart';
import 'package:clippy/core/models/remote_clip.dart';
import 'package:clippy/core/sync/state_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic, inspectable CryptoBox for engine tests.
/// fingerprint(x) == 'h:$x'; seal produces ciphertext 'enc:$x' and the same hash.
class FakeCryptoBox implements CryptoBox {
  @override
  bool get isPaired => true;

  @override
  Future<String> fingerprint(String plaintext) async => 'h:$plaintext';

  @override
  Future<EncryptedClip> seal(String plaintext, {required String source}) async =>
      EncryptedClip(
        ciphertext: 'enc:$plaintext',
        iv: 'iv',
        hash: 'h:$plaintext',
        source: source,
      );

  @override
  Future<String> open(RemoteClip clip) async {
    if (!clip.ciphertext.startsWith('enc:')) {
      throw StateError('cannot open: ${clip.ciphertext}');
    }
    return clip.ciphertext.substring('enc:'.length);
  }
}

class InMemoryStateStore implements StateStore {
  String? _hash;
  InMemoryStateStore([this._hash]);

  @override
  Future<String?> readLastAppliedHash() async => _hash;

  @override
  Future<void> writeLastAppliedHash(String hash) async => _hash = hash;
}

/// Builds a fixed clock function for deterministic tests.
DateTime Function() fixedClock(DateTime t) => () => t;

void main() {
  test('FakeCryptoBox seal/open round-trips and hash matches fingerprint', () async {
    final box = FakeCryptoBox();
    final sealed = await box.seal('hello', source: 'devA');
    expect(sealed.hash, await box.fingerprint('hello'));
    final remote = RemoteClip(
      ciphertext: sealed.ciphertext, iv: sealed.iv, hash: sealed.hash,
      source: sealed.source, timestamp: DateTime.utc(2026));
    expect(await box.open(remote), 'hello');
  });

  test('InMemoryStateStore persists last applied hash', () async {
    final s = InMemoryStateStore();
    expect(await s.readLastAppliedHash(), isNull);
    await s.writeLastAppliedHash('h:abc');
    expect(await s.readLastAppliedHash(), 'h:abc');
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/core/sync/fakes.dart`
Expected: FAIL — "Target of URI doesn't exist" for `crypto_box.dart`, `state_store.dart` (not yet created).

- [ ] **Step 3: Write the interfaces and SyncAction**

Create `lib/core/crypto/crypto_box.dart`:
```dart
import '../models/encrypted_clip.dart';
import '../models/remote_clip.dart';

/// Encrypts/decrypts clip payloads and computes the echo-guard fingerprint.
/// The fingerprint is HMAC(key, plaintext) — never a plaintext hash — so a
/// Firestore document never carries a plaintext oracle. Real AES-256-GCM
/// implementation arrives in Plan 2; the core depends only on this interface.
abstract class CryptoBox {
  Future<EncryptedClip> seal(String plaintext, {required String source});
  Future<String> open(RemoteClip clip);
  Future<String> fingerprint(String plaintext);

  /// True once a shared key has been established (QR pairing, Plan 2).
  bool get isPaired;
}
```

Create `lib/core/sync/state_store.dart`:
```dart
/// Persists the small amount of sync state that must survive process restarts.
/// v1: only lastAppliedHash, the dedup key that prevents a reconnect or cold
/// start from re-applying (clobbering) a clip this device already applied.
abstract class StateStore {
  Future<String?> readLastAppliedHash();
  Future<void> writeLastAppliedHash(String hash);
}
```

Create `lib/core/sync/sync_action.dart`:
```dart
import '../models/encrypted_clip.dart';

/// The SyncEngine emits actions instead of performing side effects, so its
/// decision logic is pure and fully testable. Platform code (Plans 3–4)
/// interprets these: UploadClip -> ClipStore.put; ApplyToClipboard ->
/// ClipboardPort.setText; OfferRestore -> show a "restore last clip" affordance.
sealed class SyncAction {
  const SyncAction();
}

class UploadClip extends SyncAction {
  final EncryptedClip clip;
  const UploadClip(this.clip);
}

class ApplyToClipboard extends SyncAction {
  final String text;
  const ApplyToClipboard(this.text);
}

class OfferRestore extends SyncAction {
  final String text;
  const OfferRestore(this.text);
}
```

- [ ] **Step 4: Run to verify the fakes' contract passes**

Run: `flutter test test/core/sync/fakes.dart`
Expected: PASS — both contract tests green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): add CryptoBox/StateStore interfaces, SyncAction, and test fakes"
```

---

### Task 4: SyncEngine — local clip path (upload / echo-suppress / skip)

**Files:**
- Create: `lib/core/sync/sync_engine.dart`
- Test: `test/core/sync/sync_engine_local_test.dart`

**Interfaces:**
- Consumes: `ClipEvent`, `EncryptedClip`, `CryptoBox`, `StateStore`, `SyncAction`/`UploadClip` (Tasks 2–3), and the test fakes (Task 3).
- Produces: `class SyncEngine` constructed as
  `SyncEngine({required CryptoBox crypto, required StateStore state, required String selfDeviceId, required DateTime Function() clock, int sizeCapBytes = 102400, Duration freshnessWindow = const Duration(seconds: 60), Duration echoWindow = const Duration(seconds: 2)})`
  with `Future<List<SyncAction>> onLocalClip(ClipEvent event)` (this task) and `Future<List<SyncAction>> onRemoteSnapshot(RemoteClip clip)` (Task 5). Later tasks/plans rely on these exact names and signatures.

Implements the spec §7 **On local clipboard change** rules:
1. If non-text, concealed, or `byteSize > sizeCapBytes` → ignore (`[]`).
2. If `expectedEchoHash != null && h == expectedEchoHash && clock() < expectedEchoExpiry` → this is the echo of what we just applied → clear `expectedEchoHash`; do not upload (`[]`).
3. Else → seal, persist `lastAppliedHash = h`, return `[UploadClip(clip)]`.

- [ ] **Step 1: Write the failing tests**

Create `test/core/sync/sync_engine_local_test.dart`:
```dart
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

  test('a fresh text copy produces an UploadClip with our source and hash', () async {
    final engine = build();
    final actions = await engine.onLocalClip(
        const ClipEvent(text: 'hello', byteSize: 5));
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

  test('echo of a just-applied remote clip within 2s is suppressed once', () async {
    // Apply a remote clip at t0 so expectedEchoHash = h:remote, expiry t0+2s.
    final engine = build(now: t0);
    final remote = RemoteClip(
      ciphertext: 'enc:remote', iv: 'iv', hash: 'h:remote',
      source: 'phoneB', timestamp: t0);
    final applied = await engine.onRemoteSnapshot(remote);
    expect(applied.single, isA<ApplyToClipboard>());

    // The watcher now fires with the identical text at t0+1s -> suppressed.
    final echo = await engine.onLocalClip(
        const ClipEvent(text: 'remote', byteSize: 6));
    expect(echo, isEmpty, reason: 'echo must not re-upload');
  });

  test('re-copying the same text LATER (after echo consumed) uploads again', () async {
    final engine = build(now: t0);
    final remote = RemoteClip(
      ciphertext: 'enc:remote', iv: 'iv', hash: 'h:remote',
      source: 'phoneB', timestamp: t0);
    await engine.onRemoteSnapshot(remote);                       // sets echo
    await engine.onLocalClip(const ClipEvent(text: 'remote', byteSize: 6)); // consumes echo

    // User copies 'remote' again intentionally -> must upload (bug the design fixes).
    final again = await engine.onLocalClip(
        const ClipEvent(text: 'remote', byteSize: 6));
    expect(again.single, isA<UploadClip>());
  });

  test('echo guard does not fire after the 2s window expires', () async {
    // Apply remote at t0; local event arrives at t0+3s -> window expired -> upload.
    final engine = SyncEngine(
      crypto: crypto, state: store, selfDeviceId: 'macA',
      clock: () => _clockValue);
    _clockValue = t0;
    final remote = RemoteClip(
      ciphertext: 'enc:remote', iv: 'iv', hash: 'h:remote',
      source: 'phoneB', timestamp: t0);
    await engine.onRemoteSnapshot(remote);
    _clockValue = t0.add(const Duration(seconds: 3));
    final late = await engine.onLocalClip(
        const ClipEvent(text: 'remote', byteSize: 6));
    expect(late.single, isA<UploadClip>());
  });
}

// Mutable clock backing for the expiry test.
DateTime _clockValue = DateTime.utc(2026);
```

- [ ] **Step 2: Run to verify the tests fail**

Run: `flutter test test/core/sync/sync_engine_local_test.dart`
Expected: FAIL — "Target of URI doesn't exist: sync_engine.dart" / `SyncEngine` undefined.

- [ ] **Step 3: Write the SyncEngine (local path + shared state; remote path stubbed to throw until Task 5)**

Create `lib/core/sync/sync_engine.dart`:
```dart
import '../crypto/crypto_box.dart';
import '../models/clip_event.dart';
import '../models/remote_clip.dart';
import 'state_store.dart';
import 'sync_action.dart';

/// The Clippy sync state machine (spec §7). Pure decision logic: it consumes
/// local clipboard events and remote snapshots and returns the actions a
/// platform should perform. Owns the echo-guard, freshness gate, and dedup.
class SyncEngine {
  final CryptoBox _crypto;
  final StateStore _state;
  final String _selfDeviceId;
  final DateTime Function() _clock;
  final int _sizeCapBytes;
  final Duration _freshnessWindow;
  final Duration _echoWindow;

  // Persisted-across-restarts dedup key, cached in memory after first load.
  String? _lastAppliedHash;
  bool _lastAppliedLoaded = false;

  // One-shot echo suppression: set when we apply a remote clip, consumed by
  // the next matching local event, and time-boxed by _echoWindow.
  String? _expectedEchoHash;
  DateTime? _expectedEchoExpiry;

  // Freshness gate applies only to the first considered snapshot of a session.
  bool _firstSnapshotConsidered = false;

  SyncEngine({
    required CryptoBox crypto,
    required StateStore state,
    required String selfDeviceId,
    required DateTime Function() clock,
    int sizeCapBytes = 102400,
    Duration freshnessWindow = const Duration(seconds: 60),
    Duration echoWindow = const Duration(seconds: 2),
  })  : _crypto = crypto,
        _state = state,
        _selfDeviceId = selfDeviceId,
        _clock = clock,
        _sizeCapBytes = sizeCapBytes,
        _freshnessWindow = freshnessWindow,
        _echoWindow = echoWindow;

  Future<void> _ensureLoaded() async {
    if (_lastAppliedLoaded) return;
    _lastAppliedHash = await _state.readLastAppliedHash();
    _lastAppliedLoaded = true;
  }

  Future<void> _setLastApplied(String hash) async {
    _lastAppliedHash = hash;
    _lastAppliedLoaded = true;
    await _state.writeLastAppliedHash(hash);
  }

  /// Spec §7 — On local clipboard change.
  Future<List<SyncAction>> onLocalClip(ClipEvent event) async {
    // Rule 1: ignore non-text, concealed/sensitive, or oversize clips.
    if (!event.isText || event.isConcealed || event.byteSize > _sizeCapBytes) {
      return const [];
    }
    final text = event.text!;
    final h = await _crypto.fingerprint(text);

    // Rule 2: one-shot, time-boxed echo suppression.
    if (_expectedEchoHash != null &&
        h == _expectedEchoHash &&
        _clock().isBefore(_expectedEchoExpiry!)) {
      _expectedEchoHash = null;
      _expectedEchoExpiry = null;
      return const [];
    }

    // Rule 3: seal and upload.
    final clip = await _crypto.seal(text, source: _selfDeviceId);
    await _setLastApplied(h);
    return [UploadClip(clip)];
  }

  /// Spec §7 — On remote snapshot. Implemented in Task 5.
  Future<List<SyncAction>> onRemoteSnapshot(RemoteClip clip) async {
    throw UnimplementedError('onRemoteSnapshot: implemented in Task 5');
  }
}
```

Note: the local-path tests exercise `onRemoteSnapshot` to set up the echo state, so those specific tests will still fail until Task 5. To keep this task's cycle honest, run only the pure-local tests now:

- [ ] **Step 4: Run the pure-local tests to verify they pass**

Run: `flutter test test/core/sync/sync_engine_local_test.dart --plain-name "a fresh text copy"`
Then: `flutter test test/core/sync/sync_engine_local_test.dart --plain-name "non-text clip is ignored"`
Then: `flutter test test/core/sync/sync_engine_local_test.dart --plain-name "concealed clip is ignored"`
Then: `flutter test test/core/sync/sync_engine_local_test.dart --plain-name "oversize clip is skipped"`
Expected: each PASS. (The three echo-related tests depend on `onRemoteSnapshot` and will pass at the end of Task 5 — do not treat them as failures of this task.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): SyncEngine local-clip path (upload/echo-suppress/skip)"
```

---

### Task 5: SyncEngine — remote snapshot path (freshness gate, dedup, apply)

**Files:**
- Modify: `lib/core/sync/sync_engine.dart` (replace the stubbed `onRemoteSnapshot`)
- Test: `test/core/sync/sync_engine_remote_test.dart`

**Interfaces:**
- Consumes: everything from Task 4 (same `SyncEngine` class and constructor).
- Produces: fully implemented `Future<List<SyncAction>> onRemoteSnapshot(RemoteClip clip)`.

Implements the spec §7 **On remote snapshot** rules:
1. If `clip.source == selfDeviceId` → ignore (`[]`).
2. If `clip.hash == lastAppliedHash` → ignore (absorbs reconnect / cold-start re-delivery).
3. If this is the **first considered snapshot of the session** AND `clock() - clip.timestamp > freshnessWindow` → do not write the clipboard; set `lastAppliedHash = clip.hash`; return `[OfferRestore(text)]`.
4. Else → decrypt; set `expectedEchoHash = clip.hash`, `expectedEchoExpiry = clock() + echoWindow`; set `lastAppliedHash = clip.hash`; return `[ApplyToClipboard(text)]`.

`_firstSnapshotConsidered` flips to true only after passing rules 1 and 2 (so a self/duplicate first delivery does not "spend" the session's freshness gate).

- [ ] **Step 1: Write the failing tests**

Create `test/core/sync/sync_engine_remote_test.dart`:
```dart
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
        ciphertext: 'enc:$text', iv: 'iv', hash: 'h:$text',
        source: source, timestamp: ts ?? t0);

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

  test('a clip equal to lastAppliedHash is ignored (reconnect re-delivery)', () async {
    final engine = build(state: InMemoryStateStore('h:hello'));
    expect(await engine.onRemoteSnapshot(remote(text: 'hello')), isEmpty);
  });

  test('first snapshot older than 60s -> OfferRestore, clipboard not written', () async {
    // now = t0; clip stamped 61s earlier.
    final engine = build(now: t0);
    final stale = remote(text: 'old', ts: t0.subtract(const Duration(seconds: 61)));
    final actions = await engine.onRemoteSnapshot(stale);
    expect((actions.single as OfferRestore).text, 'old');
    expect(await store.readLastAppliedHash(), 'h:old',
        reason: 'lastAppliedHash still recorded so it is not offered twice');
  });

  test('first snapshot within 60s is applied (fresh)', () async {
    final engine = build(now: t0);
    final fresh = remote(text: 'new', ts: t0.subtract(const Duration(seconds: 30)));
    final actions = await engine.onRemoteSnapshot(fresh);
    expect(actions.single, isA<ApplyToClipboard>());
  });

  test('freshness gate applies only to the FIRST considered snapshot', () async {
    final engine = build(now: t0);
    // First snapshot fresh -> applied, gate consumed.
    await engine.onRemoteSnapshot(
        remote(text: 'first', ts: t0.subtract(const Duration(seconds: 10))));
    // Second snapshot is old but arrives mid-session -> still applied (late Doze delivery).
    final actions = await engine.onRemoteSnapshot(
        remote(text: 'second', ts: t0.subtract(const Duration(seconds: 300))));
    expect((actions.single as ApplyToClipboard).text, 'second');
  });

  test('a self/duplicate first delivery does NOT spend the freshness gate', () async {
    final engine = build(now: t0);
    // First delivery is our own echo -> ignored, gate NOT consumed.
    await engine.onRemoteSnapshot(remote(source: 'macA'));
    // Next delivery is a genuinely stale clip -> treated as first considered -> OfferRestore.
    final actions = await engine.onRemoteSnapshot(
        remote(text: 'stale', ts: t0.subtract(const Duration(seconds: 120))));
    expect(actions.single, isA<OfferRestore>());
  });

  test('applying a remote clip arms one-shot echo suppression for the local watcher',
      () async {
    final engine = build(now: t0);
    await engine.onRemoteSnapshot(remote(text: 'sync'));
    // The clipboard watcher now fires with the applied text -> suppressed.
    final echo = await engine.onLocalClip(
        const ClipEvent(text: 'sync', byteSize: 4));
    expect(echo, isEmpty);
  });
}
```

- [ ] **Step 2: Run to verify the tests fail**

Run: `flutter test test/core/sync/sync_engine_remote_test.dart`
Expected: FAIL — `UnimplementedError: onRemoteSnapshot: implemented in Task 5`.

- [ ] **Step 3: Replace the stubbed `onRemoteSnapshot`**

In `lib/core/sync/sync_engine.dart`, replace the entire `onRemoteSnapshot` method body:
```dart
  /// Spec §7 — On remote snapshot.
  Future<List<SyncAction>> onRemoteSnapshot(RemoteClip clip) async {
    // Rule 1: never react to our own writes.
    if (clip.source == _selfDeviceId) return const [];

    // Rule 2: already applied (also absorbs reconnect / cold-start re-delivery).
    await _ensureLoaded();
    if (clip.hash == _lastAppliedHash) return const [];

    // From here this counts as a "considered" snapshot for the freshness gate.
    final isFirstConsidered = !_firstSnapshotConsidered;
    _firstSnapshotConsidered = true;

    // Rule 3: cold-start / fresh-install protection — do not clobber the live
    // clipboard with a stale clip on the first considered snapshot.
    if (isFirstConsidered &&
        _clock().difference(clip.timestamp) > _freshnessWindow) {
      final text = await _crypto.open(clip);
      await _setLastApplied(clip.hash);
      return [OfferRestore(text)];
    }

    // Rule 4: apply, and arm one-shot echo suppression for the local watcher.
    final text = await _crypto.open(clip);
    _expectedEchoHash = clip.hash;
    _expectedEchoExpiry = _clock().add(_echoWindow);
    await _setLastApplied(clip.hash);
    return [ApplyToClipboard(text)];
  }
```

- [ ] **Step 4: Run the remote tests to verify they pass**

Run: `flutter test test/core/sync/sync_engine_remote_test.dart`
Expected: PASS — all remote-path tests green.

- [ ] **Step 5: Run the full suite (local echo tests now pass too)**

Run: `flutter test`
Expected: PASS — every test green, including the three echo-related local tests from Task 4 that depended on `onRemoteSnapshot`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): SyncEngine remote-snapshot path (freshness gate, dedup, apply)"
```

---

## Self-Review

**1. Spec coverage (§7 state machine — this plan's scope):**
- Local rule 1 (ignore non-text/concealed/oversize) → Task 4 tests. ✓
- Local rule 2 (one-shot, time-boxed echo) → Task 4 tests (suppress, re-copy-later, expiry). ✓
- Local rule 3 (seal + persist + upload) → Task 4. ✓
- Remote rule 1 (ignore self) → Task 5. ✓
- Remote rule 2 (dedup vs persisted lastAppliedHash) → Task 5 (reconnect re-delivery). ✓
- Remote rule 3 (first-snapshot freshness → OfferRestore) → Task 5 (stale, and "self delivery doesn't spend the gate"). ✓
- Remote rule 4 (apply + arm echo) → Task 5. ✓
- Size cap 102400, injected clock, persisted hash, 60s/2s windows → Global Constraints + exercised in tests. ✓
- Models/interfaces for later plans (EncryptedClip.toMap without timestamp; RemoteClip.timestamp resolved; CryptoBox/StateStore) → Tasks 2–3. ✓
- Out of scope for Plan 1 (correctly deferred): real crypto, Firebase, platform clipboard, UI — Plans 2–4.

**2. Placeholder scan:** No "TBD/TODO/handle edge cases" — every step has runnable code and exact commands. The Task 4 stub `onRemoteSnapshot` throwing `UnimplementedError` is intentional and replaced in Task 5, with the run-step explicitly scoping which tests pass when. ✓

**3. Type consistency:** `SyncEngine` constructor params (`crypto`, `state`, `selfDeviceId`, `clock`, `sizeCapBytes`, `freshnessWindow`, `echoWindow`) match between Tasks 4 and 5. `CryptoBox.fingerprint/seal/open` signatures match the fakes and engine usage. `FakeCryptoBox`: `fingerprint(x)=='h:$x'` and `seal(x).hash=='h:$x'` are consistent, which the engine's local rule 3 and echo tests rely on. `SyncAction` subtypes (`UploadClip`/`ApplyToClipboard`/`OfferRestore`) are used with the same names in tests. `StateStore.readLastAppliedHash/writeLastAppliedHash` consistent throughout. ✓

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-02-clippy-plan-1-foundation.md`.
