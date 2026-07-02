import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/pairing/pairing_key.dart';

/// Persists the paired master key in the OS secure keystore
/// (macOS Keychain / Android Keystore), never in plain preferences.
class SecureKeyStore {
  static const _key = 'clippy.masterKey.v1';
  final FlutterSecureStorage _storage;

  const SecureKeyStore([this._storage = const FlutterSecureStorage()]);

  Future<PairingKey?> load() async {
    final b64 = await _storage.read(key: _key);
    if (b64 == null) return null;
    return PairingKey.fromQrPayload(b64);
  }

  Future<void> save(PairingKey key) =>
      _storage.write(key: _key, value: base64.encode(key.masterKey));

  Future<void> clear() => _storage.delete(key: _key);
}
