import 'package:clippy/core/signals/clip_signals.dart';
import 'package:clippy/platform/link_opener.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uri? uri(SignalKind k, String v) => LinkOpener.uriFor(ClipSignal(k, v));

  test('each signal opens the right kind of URI', () {
    expect(uri(SignalKind.url, 'https://github.com/x').toString(), 'https://github.com/x');
    expect(uri(SignalKind.url, 'www.example.com').toString(), 'https://www.example.com');
    expect(uri(SignalKind.phone, '+49 151 2345-6789').toString(), 'tel:+4915123456789');
    expect(uri(SignalKind.email, 'a@b.de').toString(), 'mailto:a@b.de');
    expect(uri(SignalKind.address, 'Hauptstraße 5, 10117 Berlin')!.host, 'www.google.com');
  });

  test('a clip cannot smuggle a dangerous scheme through as a "link"', () {
    expect(uri(SignalKind.url, 'javascript:alert(1)'), isNull);
    expect(uri(SignalKind.url, 'file:///etc/passwd'), isNull);
  });

  test('open() refuses anything but http(s), tel and mailto', () async {
    expect(await LinkOpener.open(Uri.parse('file:///etc/passwd')), isFalse);
    expect(await LinkOpener.open(Uri.parse('smb://host/share')), isFalse);
  });

  test('signals with no action map to nothing', () {
    expect(uri(SignalKind.date, '18:40'), isNull);
    expect(uri(SignalKind.card, '4242 4242 4242 4242'), isNull);
  });
}
