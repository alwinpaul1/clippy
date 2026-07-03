import 'dart:async';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:super_clipboard/super_clipboard.dart';

/// System-clipboard image read/write via super_clipboard, plus JPEG downscaling
/// for relay transport. Only meaningful where super_clipboard is supported
/// (macOS, Android, …); returns null / no-ops elsewhere.
abstract class ImageClipboard {
  static SystemClipboard? get _cb => SystemClipboard.instance;

  /// Read a PNG image off the clipboard as raw bytes, or null if there's none.
  static Future<Uint8List?> read() async {
    final cb = _cb;
    if (cb == null) return null;
    final reader = await cb.read();
    if (!reader.canProvide(Formats.png)) return null;
    final completer = Completer<Uint8List?>();
    reader.getFile(
      Formats.png,
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

  /// Put an image on the clipboard. [jpegBytes] is transcoded to PNG for the
  /// widest paste compatibility.
  static Future<void> write(Uint8List jpegBytes) async {
    final cb = _cb;
    if (cb == null) return;
    final png = _toPng(jpegBytes);
    if (png == null) return;
    final item = DataWriterItem();
    item.add(Formats.png(png));
    await cb.write([item]);
  }

  static Uint8List? _toPng(Uint8List jpegBytes) {
    try {
      final decoded = img.decodeImage(jpegBytes);
      if (decoded == null) return null;
      return Uint8List.fromList(img.encodePng(decoded));
    } catch (_) {
      return null;
    }
  }

  /// Downscale + JPEG-encode an image for relay transport (long edge ≤1600 px,
  /// quality 80). Returns the original bytes if decoding fails.
  static Uint8List downscaleForRelay(Uint8List input) {
    try {
      final decoded = img.decodeImage(input);
      if (decoded == null) return input;
      var im = decoded;
      const maxEdge = 1600;
      if (im.width > maxEdge || im.height > maxEdge) {
        im = im.width >= im.height
            ? img.copyResize(im, width: maxEdge)
            : img.copyResize(im, height: maxEdge);
      }
      return Uint8List.fromList(img.encodeJpg(im, quality: 80));
    } catch (_) {
      return input;
    }
  }
}
