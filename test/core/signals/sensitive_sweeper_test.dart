import 'package:clippy/core/signals/sensitive_sweeper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final t0 = DateTime(2026, 10, 18, 12);
  const card = '4242 4242 4242 4242';

  SweepClip clip(String hash, String text, Duration ago, {bool image = false}) =>
      (hash: hash, text: text, isImage: image, timestamp: t0.subtract(ago));

  test('deletes only EXPIRED sensitive clips and clears each off the clipboard', () async {
    final deleted = <String>[];
    final cleared = <String>[];
    final sw = SensitiveSweeper(
      clips: () => [
        clip('old-card', card, const Duration(minutes: 6)),
        clip('new-card', '5555 5555 5555 4444', const Duration(minutes: 1)),
        clip('old-text', 'hello there', const Duration(hours: 3)),
        clip('img', '', const Duration(hours: 3), image: true),
      ],
      delete: (h) async => deleted.addAll(h),
      clearClipboard: (t) async => cleared.add(t),
      signals: SignalCache(),
      ttl: () async => const Duration(minutes: 5),
      clock: () => t0,
    );
    expect(await sw.sweep(), ['old-card']);
    expect(deleted, ['old-card']);
    expect(cleared, [card]);
  });

  test('a clip is swept once, even if the relay has not echoed the delete yet', () async {
    var deletes = 0;
    final sw = SensitiveSweeper(
      clips: () => [clip('c', card, const Duration(minutes: 9))],
      delete: (_) async => deletes++,
      clearClipboard: (_) async {},
      signals: SignalCache(),
      ttl: () async => const Duration(minutes: 5),
      clock: () => t0,
    );
    await sw.sweep();
    await sw.sweep();
    expect(deletes, 1);
  });

  test('remaining time counts down and never goes negative', () {
    const ttl = Duration(minutes: 5);
    expect(SensitiveSweeper.remaining(t0.subtract(const Duration(minutes: 2)), ttl, now: t0),
        const Duration(minutes: 3));
    expect(SensitiveSweeper.remaining(t0.subtract(const Duration(minutes: 9)), ttl, now: t0),
        Duration.zero);
  });

  test('TTL defaults to 5 min and rejects values outside the choices', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SensitiveTtl.read(), const Duration(minutes: 5));
    await SensitiveTtl.write(15);
    expect(await SensitiveTtl.read(), const Duration(minutes: 15));
    SharedPreferences.setMockInitialValues({SensitiveTtl.prefsKey: 999});
    expect(await SensitiveTtl.read(), const Duration(minutes: 5));
  });
}
