import 'package:clippy/app/ui_kit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 18, 16, 0); // a Sunday

  String age(Duration ago) => relativeAge(now.subtract(ago), now: now);

  test('minutes and hours today', () {
    expect(age(const Duration(seconds: 20)), 'now');
    expect(age(const Duration(minutes: 4)), '4 min');
    expect(age(const Duration(hours: 3)), '3 h');
  });

  test('an old clip shows a day or a date, never a bare clock time', () {
    expect(relativeAge(DateTime(2026, 10, 17, 9), now: now), 'Yesterday');
    expect(relativeAge(DateTime(2026, 10, 14, 9), now: now), 'Wed');
    expect(relativeAge(DateTime(2026, 10, 9, 16, 4), now: now), 'Oct 9');
    expect(relativeAge(DateTime(2025, 12, 31), now: now), 'Dec 31, 2025');
  });
}
