import 'package:clippy/core/models/encrypted_clip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const clip = EncryptedClip(
      ciphertext: 'ct', iv: 'iv', hash: 'h', source: 'devA');

  test('toMap contains all fields (no timestamp — server adds it)', () {
    final m = clip.toMap();
    expect(m, {'ciphertext': 'ct', 'iv': 'iv', 'hash': 'h', 'source': 'devA'});
    expect(m.containsKey('timestamp'), isFalse);
  });

  test('fromMap round-trips via value equality', () {
    expect(EncryptedClip.fromMap(clip.toMap()), clip);
  });
}
