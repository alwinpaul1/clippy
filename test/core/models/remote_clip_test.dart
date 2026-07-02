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
