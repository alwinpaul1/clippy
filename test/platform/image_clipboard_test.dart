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
