import 'dart:async';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:super_clipboard/super_clipboard.dart';

/// System-clipboard image read/write via super_clipboard, plus JPEG downscaling
/// for relay transport. Only meaningful where super_clipboard is supported
/// (macOS, Android, …); returns null / no-ops elsewhere.
abstract class ImageClipboard {
  static SystemClipboard? get _cb => SystemClipboard.instance;

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

  /// Put an image on the clipboard. Non-PNG bytes are transcoded to PNG for
  /// the widest paste compatibility; PNG bytes go on as-is (transcoding a
  /// large screenshot in pure Dart takes seconds and changes nothing).
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

  static Uint8List? _toPng(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      return Uint8List.fromList(img.encodePng(decoded));
    } catch (_) {
      return null;
    }
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
