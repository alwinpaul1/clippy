import 'package:shared_preferences/shared_preferences.dart';

import '../sync/state_store.dart';

/// StateStore backed by shared_preferences. Persists only lastAppliedHash — an
/// HMAC fingerprint that is not sensitive (it is already stored alongside each
/// clip). The AES master key is NOT kept here; it lives in the OS secure
/// keystore (Keychain / Android Keystore), handled by platform pairing code.
class PrefsStateStore implements StateStore {
  static const _key = 'clippy.lastAppliedHash';

  final SharedPreferences _prefs;

  PrefsStateStore._(this._prefs);

  static Future<PrefsStateStore> create() async =>
      PrefsStateStore._(await SharedPreferences.getInstance());

  @override
  Future<String?> readLastAppliedHash() async {
    // The UI isolate and the Android service isolate both run engines against
    // this key (dedup Rule 2b). SharedPreferences caches per isolate, so
    // reload before reading or one isolate re-uploads what the other already
    // synced. Clip events are infrequent; the disk re-read is negligible.
    try {
      await _prefs.reload();
    } catch (_) {
      // Reload unsupported (tests) — cached value is still correct there.
    }
    return _prefs.getString(_key);
  }

  @override
  Future<void> writeLastAppliedHash(String hash) async =>
      _prefs.setString(_key, hash);
}
