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
