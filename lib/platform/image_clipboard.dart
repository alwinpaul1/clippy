import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:super_clipboard/super_clipboard.dart';

/// System-clipboard image read/write via super_clipboard. Incoming images are
/// put on the clipboard in their own format (bytes verbatim — instant and
/// lossless); only meaningful where super_clipboard is supported (macOS,
/// Android, …); returns null / no-ops elsewhere.
abstract class ImageClipboard {
  static SystemClipboard? get _cb => SystemClipboard.instance;
  static const _androidChannel = MethodChannel('clippy/share');

  /// Read an image off the clipboard as raw bytes, or null if there's none.
  /// Tries several formats (macOS screenshots land as PNG; other apps may use
  /// JPEG/TIFF/…). The `image` package decodes whichever we get.
  static Future<Uint8List?> read() async {
    final cb = _cb;
    if (cb == null) return null;
    final reader = await cb.read();
    for (final fmt in [
      Formats.png,
      Formats.jpeg,
      Formats.tiff,
      Formats.gif,
      Formats.bmp,
    ]) {
      if (!reader.canProvide(fmt)) continue;
      final bytes = await _readFile(reader, fmt);
      if (bytes != null && bytes.isNotEmpty) return bytes;
    }
    return null;
  }

  static Future<Uint8List?> _readFile(ClipboardReader reader, FileFormat fmt) {
    final completer = Completer<Uint8List?>();
    reader.getFile(
      fmt,
      (file) async {
        try {
          completer.complete(await file.readAll());
        } catch (_) {
          if (!completer.isCompleted) completer.complete(null);
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    return completer.future;
  }

  /// Put an image on the clipboard in its own format, bytes verbatim — instant
  /// and lossless at any size. On macOS/Windows a PNG rendition is attached
  /// lazily (super_clipboard provides it on demand), so the rare paste target
  /// that only accepts PNG still works without paying the encode up front.
  /// Android needs no PNG rendition — its clipboard is a format-agnostic content
  /// URI, so a JPEG/webp/… pastes into any app as-is. Unrecognized bytes fall
  /// back to a one-off PNG transcode.
  static Future<void> write(Uint8List bytes) async {
    // Android: write via the native ClipboardManager + FileProvider URI.
    // super_clipboard's own image write serves an EMPTY file to paste targets
    // (its DataProvider returns no bytes), so images it wrote could not be
    // pasted into other apps. The native path lives on the UI-isolate engine's
    // channel; from a background isolate the call throws (no handler) and we
    // fall back to super_clipboard.
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final ok = await _androidChannel.invokeMethod<bool>(
          'writeClipImage', {'bytes': bytes, 'ext': _extFor(bytes)},
        );
        if (ok == true) return;
      } catch (_) {
        // No handler (background isolate) — fall through to super_clipboard.
      }
    }
    final cb = _cb;
    if (cb == null) return;
    final fmt = imageFormatFor(bytes);
    final item = DataWriterItem();
    if (fmt == null) {
      final png = await encodeToPng(bytes);
      if (png == null) return;
      item.add(Formats.png(png));
    } else {
      item.add(fmt(bytes));
      if (!identical(fmt, Formats.png) && _lazyPngPlatform) {
        item.add(Formats.png.lazy(() async => await encodeToPng(bytes) ?? bytes));
      }
    }
    await cb.write([item]);
  }

  /// File extension for the native clipboard write, from the image's format.
  static String _extFor(Uint8List b) {
    final fmt = imageFormatFor(b);
    if (identical(fmt, Formats.jpeg)) return 'jpg';
    if (identical(fmt, Formats.gif)) return 'gif';
    if (identical(fmt, Formats.webp)) return 'webp';
    if (identical(fmt, Formats.bmp)) return 'bmp';
    return 'png';
  }

  /// Platforms where super_clipboard provides lazy data on demand (rather than
  /// resolving it eagerly), so a lazy PNG rendition never blocks the write.
  static bool get _lazyPngPlatform =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  /// The super_clipboard format matching the image's magic bytes, or null if
  /// the bytes aren't a recognized image format.
  @visibleForTesting
  static SimpleFileFormat? imageFormatFor(Uint8List b) {
    if (b.length >= 4) {
      if (b[0] == 0x89 && b[1] == 0x50) return Formats.png;
      if (b[0] == 0xFF && b[1] == 0xD8) return Formats.jpeg;
      if (b[0] == 0x47 && b[1] == 0x49) return Formats.gif;
      if (b[0] == 0x42 && b[1] == 0x4D) return Formats.bmp;
      if (b.length >= 12 &&
          b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
          b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
        return Formats.webp;
      }
    }
    return null;
  }

  /// Transcode arbitrary image bytes to PNG. Used only for the lazy desktop PNG
  /// rendition (computed on demand) and the unrecognized-format fallback — never
  /// on the fast path. Native (Skia) codec, with a pure-Dart fallback for
  /// isolates where the native codec is unavailable. Null if undecodable.
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

  /// A format-agnostic fingerprint of an image's *picture* rather than its raw
  /// bytes: a JPEG and the PNG it gets re-encoded to on a clipboard round-trip
  /// decode to the same pixels, so they share one fingerprint. The sync layer
  /// uses this to recognise an image it just received coming back off the
  /// clipboard in a different format (the receive→re-read echo) — a raw-byte or
  /// content-hash compare can't, because JPEG≠PNG bytes. Null if undecodable.
  static Future<String?> fingerprint(Uint8List bytes) async {
    ui.Image? image;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width;
      final h = descriptor.height;
      // Decode to a small fixed raster — cheap, and identical for either format
      // of the same picture.
      final codec = await descriptor.instantiateCodec(
        targetWidth: 64,
        targetHeight: 64,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return '${w}x$h:${_fnv1a(data.buffer.asUint8List())}';
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
    }
  }

  /// FNV-1a 32-bit — a fast non-crypto hash, enough for a stable dedup key.
  static int _fnv1a(Uint8List data) {
    var hash = 0x811c9dc5;
    for (final b in data) {
      hash = (hash ^ b) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// Prepare an image for relay transport: the original bytes, untouched —
  /// no downscaling, no re-encoding, ever. Returns the bytes plus their mime
  /// type; [mime] is the caller's hint, else it's sniffed from the bytes.
  /// The relay's maxCiphertextChars is sized to fit real screenshots raw.
  static (Uint8List, String) prepareForRelay(Uint8List input, {String? mime}) {
    return (input, mime ?? _sniffMime(input));
  }

  static String _sniffMime(Uint8List b) {
    if (b.length >= 4) {
      if (b[0] == 0x89 && b[1] == 0x50) return 'image/png';
      if (b[0] == 0xFF && b[1] == 0xD8) return 'image/jpeg';
      if (b[0] == 0x47 && b[1] == 0x49) return 'image/gif';
      if (b[0] == 0x42 && b[1] == 0x4D) return 'image/bmp';
    }
    return 'image/png';
  }
}
