import 'dart:typed_data';

import 'package:clippy/platform/image_clipboard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:super_clipboard/super_clipboard.dart';

void main() {
  // dart:ui image codecs need the engine binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('imageFormatFor (magic-byte format detection)', () {
    test('PNG', () {
      expect(ImageClipboard.imageFormatFor(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
          same(Formats.png));
    });
    test('JPEG', () {
      expect(ImageClipboard.imageFormatFor(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])),
          same(Formats.jpeg));
    });
    test('GIF', () {
      expect(ImageClipboard.imageFormatFor(Uint8List.fromList([0x47, 0x49, 0x46, 0x38])),
          same(Formats.gif));
    });
    test('BMP', () {
      expect(ImageClipboard.imageFormatFor(Uint8List.fromList([0x42, 0x4D, 0x00, 0x00])),
          same(Formats.bmp));
    });
    test('WEBP', () {
      final webp = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, //
      ]);
      expect(ImageClipboard.imageFormatFor(webp), same(Formats.webp));
    });
    test('unrecognized bytes -> null', () {
      expect(ImageClipboard.imageFormatFor(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });
  });

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

  group('fingerprint (format-agnostic image identity)', () {
    // A picture with structure, so JPEG artefacts and the raster hash are
    // meaningful (not a degenerate solid block).
    Uint8List sampleJpeg({int seed = 0}) {
      final im = img.Image(width: 32, height: 32);
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
          im.setPixelRgb(x, y, (x * 8 + seed) % 256, (y * 8) % 256, (x + y) % 256);
        }
      }
      return Uint8List.fromList(img.encodeJpg(im, quality: 90));
    }

    test('a JPEG and its PNG re-encode share one fingerprint', () async {
      final jpeg = sampleJpeg();
      // The clipboard round-trip form: macOS/Windows hand the image back as PNG.
      final png = await ImageClipboard.encodeToPng(jpeg);
      expect(png, isNotNull);
      expect(jpeg[0], 0xFF); // JPEG
      expect(png![0], 0x89); // PNG — different bytes...

      final fpJpeg = await ImageClipboard.fingerprint(jpeg);
      final fpPng = await ImageClipboard.fingerprint(png);
      expect(fpJpeg, isNotNull);
      expect(fpJpeg, fpPng); // ...same picture → same fingerprint
    });

    test('different pictures get different fingerprints', () async {
      final a = await ImageClipboard.fingerprint(sampleJpeg(seed: 0));
      final b = await ImageClipboard.fingerprint(sampleJpeg(seed: 133));
      expect(a, isNotNull);
      expect(a, isNot(b));
    });

    test('undecodable bytes -> null', () async {
      expect(
        await ImageClipboard.fingerprint(Uint8List.fromList([1, 2, 3, 4])),
        isNull,
      );
    });
  });
}
