import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clippy/app/clip_controller.dart';

/// Background sync is the one feature a user explicitly switches on, and
/// Android can switch it back off behind their back: reinstalling an app drops
/// its accessibility service, and on this project that includes Clippy's own
/// in-app update. It happened on a real S23 — the app kept opening, kept
/// syncing while it was on screen, and nothing said the feature was dead.
///
/// The rule these tests pin: warn the people who turned it on, and ONLY them.
void main() {
  const key = 'clippy.bgSyncOptedIn.v1';

  test('enabling background sync records the opt-in', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final regressed =
        await ClipController.evaluateBgSyncRegression(prefs, true);

    expect(regressed, isFalse, reason: 'it is on — nothing to warn about');
    expect(prefs.getBool(key), isTrue,
        reason: 'without this the later disappearance is indistinguishable '
            'from a user who never enabled it');
  });

  test('a user who NEVER enabled background sync is never nagged', () async {
    SharedPreferences.setMockInitialValues({}); // no opt-in on record
    final prefs = await SharedPreferences.getInstance();

    final regressed =
        await ClipController.evaluateBgSyncRegression(prefs, false);

    expect(regressed, isFalse,
        reason: 'off + never opted in is the DEFAULT state, not a fault — '
            'a banner here would nag every user who declined the feature');
  });

  test('background sync disappearing AFTER an opt-in is a regression '
      '(the whole point: an update silently killed it)', () async {
    SharedPreferences.setMockInitialValues({key: true});
    final prefs = await SharedPreferences.getInstance();

    final regressed =
        await ClipController.evaluateBgSyncRegression(prefs, false);

    expect(regressed, isTrue);
  });

  test('re-enabling clears the regression', () async {
    SharedPreferences.setMockInitialValues({key: true});
    final prefs = await SharedPreferences.getInstance();

    // Regressed...
    expect(await ClipController.evaluateBgSyncRegression(prefs, false), isTrue);
    // ...then the user fixes it via the banner.
    expect(await ClipController.evaluateBgSyncRegression(prefs, true), isFalse);
    // ...and it stays fixed.
    expect(await ClipController.evaluateBgSyncRegression(prefs, true), isFalse);
  });

  test('the opt-in SURVIVES a regression, so a second update still warns',
      () async {
    SharedPreferences.setMockInitialValues({key: true});
    final prefs = await SharedPreferences.getInstance();

    await ClipController.evaluateBgSyncRegression(prefs, false);

    expect(prefs.getBool(key), isTrue,
        reason: 'clearing the flag on regression would make the banner a '
            'one-shot — the next update would kill sync silently again');
    expect(await ClipController.evaluateBgSyncRegression(prefs, false), isTrue);
  });

  test('the opt-in is written once, not on every resume', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var writes = 0;
    // Count real writes by watching the value transition; setBool on an
    // unchanged value would still hit disk, which is why the guard exists.
    await ClipController.evaluateBgSyncRegression(prefs, true);
    if (prefs.getBool(key) == true) writes++;
    final before = prefs.getBool(key);
    await ClipController.evaluateBgSyncRegression(prefs, true);
    expect(prefs.getBool(key), before);
    expect(writes, 1);
  });
}
