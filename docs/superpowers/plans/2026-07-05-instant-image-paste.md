# Instant Image Paste Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make non-PNG images (JPEG/webp/…) land on the receiving device's clipboard near-instantly instead of seconds late, by replacing the pure-Dart PNG transcode with Flutter's native Skia codec.

**Architecture:** `ImageClipboard.write()` transcodes incoming non-PNG images to PNG before putting them on the clipboard. Today that transcode uses the pure-Dart `image` package (seconds for a large photo). Replace it with a `dart:ui` (Skia) decode+encode (milliseconds, same PNG output), keeping the pure-Dart encoder as a fallback for isolates where the native codec is unavailable. Single-file code change plus on-device verification.

**Tech Stack:** Flutter 3.44.4 / Dart, `dart:ui` image codec, `super_clipboard` (clipboard write), `package:image` (fallback encoder), `flutter_test`.

## Global Constraints

- Only file to modify for the code change: `lib/platform/image_clipboard.dart`. No other pipeline file changes.
- Output format must stay **PNG** — no paste-compatibility change on any platform (Android/macOS/Windows).
- The already-PNG fast path (magic bytes `0x89 0x50`) must remain a pass-through (no re-encode).
- The pure-Dart `package:image` transcode must be retained as a fallback; behavior on native-codec failure must be exactly today's (never worse).
- Every native `ui.Image` obtained must be `dispose()`d (no native-memory leak).
- Package name for imports is `clippy` (`package:clippy/...`).

---

### Task 1: Native-codec PNG transcode with pure-Dart fallback

**Files:**
- Modify: `lib/platform/image_clipboard.dart` (replace `_toPng` and `write`; add imports)
- Test: `test/platform/image_clipboard_test.dart` (create)

**Interfaces:**
- Produces: `static Future<Uint8List?> ImageClipboard.encodeToPng(Uint8List bytes)` — returns PNG bytes for any decodable image (PNG input returned as-is by identity), or `null` if undecodable. Annotated `@visibleForTesting`.
- Consumes: nothing new. `write()` is rewired to call `encodeToPng`.

- [ ] **Step 1: Write the failing test**

Create `test/platform/image_clipboard_test.dart`:

```dart
import 'dart:typed_data';

import 'package:clippy/platform/image_clipboard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  // dart:ui image codecs need the engine binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('encodeToPng returns PNG bytes unchanged (identity pass-through)', () async {
    final png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
    final out = await ImageClipboard.encodeToPng(png);
    expect(out, same(png));
  });

  test('encodeToPng converts JPEG to PNG', () async {
    final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 4, height: 4)));
    // sanity: the fixture really is JPEG
    expect(jpeg[0], 0xFF);
    expect(jpeg[1], 0xD8);

    final out = await ImageClipboard.encodeToPng(jpeg);
    expect(out, isNotNull);
    // PNG signature
    expect(out![0], 0x89);
    expect(out[1], 0x50);
  });

  test('encodeToPng returns null for undecodable bytes', () async {
    final out = await ImageClipboard.encodeToPng(Uint8List.fromList([1, 2, 3, 4]));
    expect(out, isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/platform/image_clipboard_test.dart`
Expected: FAIL — `The method 'encodeToPng' isn't defined for the type 'ImageClipboard'` (compile error).

- [ ] **Step 3: Write minimal implementation**

Edit `lib/platform/image_clipboard.dart`.

Add imports at the top (alongside the existing `dart:async`, `dart:typed_data`, `package:image/image.dart`, `package:super_clipboard/super_clipboard.dart`):

```dart
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
```

Replace the existing `write()` method:

```dart
  static Future<void> write(Uint8List bytes) async {
    final cb = _cb;
    if (cb == null) return;
    final isPng = bytes.length >= 2 && bytes[0] == 0x89 && bytes[1] == 0x50;
    final png = isPng ? bytes : _toPng(bytes);
    if (png == null) return;
    final item = DataWriterItem();
    item.add(Formats.png(png));
    await cb.write([item]);
  }
```

with:

```dart
  static Future<void> write(Uint8List bytes) async {
    final cb = _cb;
    if (cb == null) return;
    final png = await encodeToPng(bytes);
    if (png == null) return;
    final item = DataWriterItem();
    item.add(Formats.png(png));
    await cb.write([item]);
  }

  /// Transcode arbitrary image bytes to PNG for the clipboard. PNG input is
  /// returned untouched. Non-PNG input is encoded with the native (Skia) codec
  /// — milliseconds even for a large photo — and only falls back to the
  /// pure-Dart encoder if the native codec is unavailable (e.g. certain
  /// background isolates). Returns null if the bytes can't be decoded at all.
  @visibleForTesting
  static Future<Uint8List?> encodeToPng(Uint8List bytes) async {
    final isPng = bytes.length >= 2 && bytes[0] == 0x89 && bytes[1] == 0x50;
    if (isPng) return bytes;
    return await _toPngNative(bytes) ?? _toPngDart(bytes);
  }

  /// Native Skia decode+encode. Fast; returns null (→ fall back) on any failure.
  static Future<Uint8List?> _toPngNative(Uint8List bytes) async {
    ui.Image? image;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
    }
  }
```

Rename the existing `_toPng` to `_toPngDart` (body unchanged), so it reads:

```dart
  /// Pure-Dart fallback encoder (slow for large images). Used only when the
  /// native codec is unavailable.
  static Uint8List? _toPngDart(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      return Uint8List.fromList(img.encodePng(decoded));
    } catch (_) {
      return null;
    }
  }
```

Also update the class doc comment's first line (currently mentions "JPEG downscaling for relay transport") only if it now misstates behavior — leave it if unrelated. Do not touch `read()`, `prepareForRelay()`, or `_sniffMime()`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/platform/image_clipboard_test.dart`
Expected: PASS (3 tests). If the JPEG→PNG test passes via the native path, great; if the native codec is unavailable in the test harness it falls through to `_toPngDart` and still passes (the test asserts the PNG-output contract, not which path produced it).

- [ ] **Step 5: Run the analyzer**

Run: `flutter analyze lib/platform/image_clipboard.dart test/platform/image_clipboard_test.dart`
Expected: No issues. (If `_toPngDart` is reported unused, that means `encodeToPng` isn't calling it — fix the `??` fallback.)

- [ ] **Step 6: Run the full existing suite to confirm no regressions**

Run: `flutter test`
Expected: All pass (the change is additive; `write()`'s external behavior — PNG on clipboard — is unchanged).

- [ ] **Step 7: Commit**

```bash
git add lib/platform/image_clipboard.dart test/platform/image_clipboard_test.dart
git commit -m "perf(image): encode incoming images to PNG via native Skia codec

Non-PNG images (JPEG/webp/…) were transcoded to PNG with the pure-Dart
image package on the receiver, taking seconds before the image was
pasteable. Encode via dart:ui's native codec instead (milliseconds, same
PNG output), keeping the pure-Dart encoder as a fallback for isolates
where the native codec is unavailable.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: On-device verification (behavioral)

**Files:** none (verification only). No commit unless a fix is needed.

**Goal:** Prove the image now lands near-instantly on the receiver, PNG stays instant, the pasted image is intact on each platform, and the background-isolate (swiped-away) path still works.

- [ ] **Step 1: Build and install the app on two paired devices**

At minimum the Galaxy S23 (`adb -s R5CW148JS4X install -r build/app/outputs/flutter-apk/app-release.apk` after `flutter build apk --release`) plus one desktop (macOS) instance, both signed into the same room.

- [ ] **Step 2: Non-PNG latency test (the fix)**

Copy a large **JPEG/photo** (e.g. a camera photo) on the desktop. Watch the phone.
Expected: the image appears in Clippy's list under the sender's device and is on the phone's clipboard within well under a second (previously several seconds). Repeat phone→desktop.

- [ ] **Step 3: PNG regression test**

Copy a **PNG screenshot** on one device.
Expected: still instant on the other (unchanged fast path).

- [ ] **Step 4: Paste-integrity test on every platform**

After a JPEG sync, paste into an image-accepting app on Android (e.g. a chat/compose field), macOS (Preview/Notes/Messages), and Windows if available.
Expected: the pasted image is the correct, intact picture (PNG on the clipboard, universally pasteable).

- [ ] **Step 5: Background-isolate (swiped-away) path**

On the phone, swipe Clippy from recents, then copy a JPEG on the desktop. Bring the phone's clipboard into an app and paste (or reopen Clippy to confirm it synced).
Expected: the image applied. If it did **not** apply while swiped away, the native codec is unavailable in the foreground-service isolate and it fell back to pure-Dart — confirm the image still eventually applies (correctness preserved). Note the observed behavior; if the swiped-away image is still slow, that is the pure-Dart fallback doing its job and is acceptable per the spec.

- [ ] **Step 6: Record the result**

Note before/after latency for the JPEG case (was seconds → now sub-second) in the PR description. No code commit in this task unless a defect is found.

---

## Notes for the implementer

- `ui.ImageDescriptor.encoded` / `instantiateCodec` / `getNextFrame` / `toByteData(format: ui.ImageByteFormat.png)` are the standard `dart:ui` decode→encode chain; they decode any format Skia supports (PNG/JPEG/webp/gif/bmp) and encode PNG natively.
- `encodeToPng` returns the **same instance** for PNG input (`return bytes`), which is why the pass-through test uses `same()`. Do not copy the buffer.
- Keep `_toPngDart` and the `package:image` import — they are the fallback. `flutter analyze` will flag them as unused if the fallback wiring is wrong, which is a useful check.
