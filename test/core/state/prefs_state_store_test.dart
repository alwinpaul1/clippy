import 'package:clippy/core/state/prefs_state_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('returns null when nothing has been written', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PrefsStateStore.create();
    expect(await store.readLastAppliedHash(), isNull);
  });

  test('write then read returns the persisted hash', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PrefsStateStore.create();
    await store.writeLastAppliedHash('h:abc');
    expect(await store.readLastAppliedHash(), 'h:abc');
  });

  test('a later write overwrites the previous value', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PrefsStateStore.create();
    await store.writeLastAppliedHash('h:first');
    await store.writeLastAppliedHash('h:second');
    expect(await store.readLastAppliedHash(), 'h:second');
  });

  test('value survives a fresh store over the same backing prefs (restart)',
      () async {
    SharedPreferences.setMockInitialValues({});
    final first = await PrefsStateStore.create();
    await first.writeLastAppliedHash('h:persisted');
    // Simulate a process restart: a new store reads the same prefs.
    final second = await PrefsStateStore.create();
    expect(await second.readLastAppliedHash(), 'h:persisted');
  });
}
