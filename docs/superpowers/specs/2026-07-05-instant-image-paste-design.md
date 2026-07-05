# Instant image paste via native PNG encoding

**Date:** 2026-07-05
**Status:** Implemented (approach revised during on-device verification — see revision note)
**Scope:** `lib/platform/image_clipboard.dart`, `MainActivity.kt`, `AndroidManifest.xml`

## Revision note (what was actually built)

On-device verification showed the original plan — encode every non-PNG image
to PNG via the native Skia codec — did **not** meet "zero delay": PNG-encoding a
large bitmap is inherently CPU-heavy even natively (measured on a Galaxy S23:
400px = 109 ms, 2000px = 1.1 s, **12MP = 8.4 s**). "Fast with no quality loss"
requires **no re-encode at all**. The final approach:

1. **Write the image in its native format, bytes verbatim** — instant at any
   size, lossless. `imageFormatFor` picks the super_clipboard format by magic
   bytes; the pure-Dart/Skia PNG encode (`encodeToPng`) is retained only for the
   lazy desktop PNG rendition and the unrecognized-format fallback.
2. **macOS/Windows:** attach a PNG rendition **lazily** (`Formats.png.lazy`) so a
   PNG-only paste target still works, computed on demand — never blocking.
3. **Android paste fix:** super_clipboard's own image write serves an **empty
   file** to paste targets (its `DataProvider` returns no bytes) — and the
   required `SuperClipboardDataProvider` was never declared, so image paste into
   other apps had never worked. Fix = (a) declare the provider in the manifest,
   and (b) write images to the clipboard **natively** via `ClipboardManager` +
   a FileProvider content URI (new `writeClipImage` method on the `clippy/share`
   channel), bypassing super_clipboard's broken serving. Verified: a synced JPEG
   now pastes as a real image into Gmail. Limitation: the native write runs on
   the UI-isolate engine's channel; a receive while Clippy is swiped away (FGS
   isolate) falls back to super_clipboard.

The sections below are the original design and are kept for history.

---


## Problem

A friend reported that "some images" sync slowly: the image *does* arrive, but
it lands on the receiving device's clipboard several seconds late. Only *some*
images are affected — screenshots (PNG) are instant, photos/other images
(JPEG/webp/gif/bmp) are slow.

### Root cause

`ImageClipboard.write()` puts incoming images on the system clipboard. It
already fast-paths PNG bytes straight onto the clipboard (instant), but for any
non-PNG image it calls `_toPng()`, which transcodes to PNG using the pure-Dart
`image` package:

```dart
final decoded = img.decodeImage(bytes);   // pure-Dart decode
return Uint8List.fromList(img.encodePng(decoded));  // pure-Dart PNG encode
```

For a large photo this decode+encode takes **seconds** (the code's own comment
acknowledges this), and it runs on the receive path before the image is
pasteable. That is the only multi-second delay in the entire sync pipeline.

### Why the rest of the pipeline is already fast (out of scope, confirmed)

An inventory of the whole pipeline found every other path is already
effectively instant, so no changes are needed there:

- Relay (`server/lib/relay.dart`): push-on-receive, no batching/timers.
- Windows clipboard detection: event-driven (`WM_CLIPBOARDUPDATE`).
- macOS clipboard detection: 100 ms `changeCount` poll (~50 ms avg).
- Android background capture: inotify-driven queue drain (instant).
- Incoming apply (`clip_controller`, `foreground_service`): applied the moment
  the WebSocket message arrives.
- Outgoing images: sent raw, no re-encode (`prepareForRelay` is a pass-through).

The transcode is the lone multi-second offender, so fixing it delivers the
"zero delay for images on all platforms" goal.

## Approach

Keep the **output format identical (PNG)** — PNG pastes universally on Android,
macOS, and Windows, so there is no cross-platform compatibility change — but
replace the slow pure-Dart encoder with Flutter's built-in **Skia (`dart:ui`)
codec**, which decodes and encodes natively in milliseconds.

Rejected alternatives:

- **Write the native format (JPEG-as-JPEG, no transcode):** truly zero work,
  but breaks paste compatibility — Windows clipboard images generally require
  DIB/PNG, and some macOS apps only read `public.png`. Trades latency for a
  correctness risk. Rejected.
- **Transcode on the sender:** moves the multi-second delay to the copying
  device and inflates the payload (PNG > JPEG → slower transfer), fighting the
  existing "send raw, never re-encode" design. Rejected.

## Design

### The change

In `lib/platform/image_clipboard.dart`, `write()` keeps its existing structure:

1. Sniff the magic bytes. If already PNG → write to clipboard as-is (unchanged,
   instant).
2. If non-PNG → transcode to PNG, then write.

Only step 2's transcode changes. New native encoder:

```dart
import 'dart:ui' as ui;

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
    return null;               // signal: fall back to pure-Dart
  } finally {
    image?.dispose();          // free native memory
  }
}
```

`write()` tries the native encoder first; if it returns null (codec threw or is
unavailable in the current isolate), it falls back to the existing pure-Dart
`_toPng()`. The pure-Dart `_toPng` and its `package:image` import are retained
solely as this fallback.

### Isolate availability

`write()` is called from two places:

- **UI isolate** (`clip_controller.dart`): `dart:ui` codecs are fully available.
  This is the common case (app foreground or recently backgrounded).
- **Headless foreground-service isolate** (`foreground_service.dart`,
  `_applyIncoming`): used only when the app is swiped away while receiving.
  Whether `dart:ui` image codecs run here must be verified on-device. If they
  do → even this case is instant. If they do not → the native encoder throws,
  the pure-Dart fallback runs, and behavior is exactly today's (never worse).

No `WidgetsFlutterBinding` calls are added; we rely on the ambient engine.

### What does NOT change

- The already-PNG fast path.
- Output format (still PNG) — no paste-compatibility change on any platform.
- Every other file in the pipeline.
- Outgoing image handling (`prepareForRelay` stays a raw pass-through).

## Error handling

- Native decode/encode failure → return null → pure-Dart fallback.
- Pure-Dart fallback failure (already handled today) → `write()` returns without
  writing; the clip stays in room history and applies on next app open.
- `image.dispose()` in `finally` guarantees no native-memory leak on any path.

## Testing / verification

- **Behavioral, on-device (primary):** copy a large JPEG/photo on device A;
  confirm it lands on device B's clipboard near-instantly (was seconds). Copy a
  PNG screenshot; confirm still instant. Paste on Android, macOS, and Windows to
  confirm the pasted image is intact.
- **Timing proof:** measure `_toPngNative` vs `_toPng` wall-clock on the same
  large non-PNG image; expect ms vs seconds.
- **Fallback:** confirm that if the native path is forced to fail, the pure-Dart
  path still produces a valid PNG (behavior unchanged).
- **Unit (if a harness fits):** `_toPngNative` on a small JPEG returns bytes with
  a PNG signature (`0x89 0x50`).

## Success criteria

- Non-PNG images land on the receiver's clipboard with no perceptible delay
  (sub-second), matching PNG images.
- No change to which images are pasteable on any platform.
- Diff limited to `lib/platform/image_clipboard.dart`.
