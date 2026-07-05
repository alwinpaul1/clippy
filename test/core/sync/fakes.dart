import 'package:clippy/core/crypto/crypto_box.dart';
import 'package:clippy/core/models/encrypted_clip.dart';
import 'package:clippy/core/models/remote_clip.dart';
import 'package:clippy/core/sync/state_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic, inspectable CryptoBox for engine tests.
/// fingerprint(x) == 'h:$x'; seal produces ciphertext 'enc:$x' and the same hash.
class FakeCryptoBox implements CryptoBox {
  @override
  bool get isPaired => true;

  @override
  Future<String> fingerprint(String plaintext) async => 'h:$plaintext';

  @override
  Future<EncryptedClip> seal(String plaintext, {required String source}) async =>
      EncryptedClip(
        ciphertext: 'enc:$plaintext',
        iv: 'iv',
        hash: 'h:$plaintext',
        source: source,
      );

  @override
  Future<String> open(RemoteClip clip) async {
    if (!clip.ciphertext.startsWith('enc:')) {
      throw StateError('cannot open: ${clip.ciphertext}');
    }
    return clip.ciphertext.substring('enc:'.length);
  }

  @override
  Future<List<String>> openAll(List<RemoteClip> clips) async =>
      [for (final c in clips) await open(c)];
}

class InMemoryStateStore implements StateStore {
  String? _hash;
  InMemoryStateStore([this._hash]);

  @override
  Future<String?> readLastAppliedHash() async => _hash;

  @override
  Future<void> writeLastAppliedHash(String hash) async => _hash = hash;
}

/// Builds a fixed clock function for deterministic tests.
DateTime Function() fixedClock(DateTime t) => () => t;

void main() {
  test('FakeCryptoBox seal/open round-trips and hash matches fingerprint',
      () async {
    final box = FakeCryptoBox();
    final sealed = await box.seal('hello', source: 'devA');
    expect(sealed.hash, await box.fingerprint('hello'));
    final remote = RemoteClip(
        ciphertext: sealed.ciphertext,
        iv: sealed.iv,
        hash: sealed.hash,
        source: sealed.source,
        timestamp: DateTime.utc(2026));
    expect(await box.open(remote), 'hello');
  });

  test('InMemoryStateStore persists last applied hash', () async {
    final s = InMemoryStateStore();
    expect(await s.readLastAppliedHash(), isNull);
    await s.writeLastAppliedHash('h:abc');
    expect(await s.readLastAppliedHash(), 'h:abc');
  });
}
