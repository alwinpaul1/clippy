import 'package:clippy/app/theme.dart';
import 'package:clippy/app/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(String value, ValueChanged<String> onChanged, {bool reduce = false}) =>
    MaterialApp(
      theme: lightTheme,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: Scaffold(
          body: Center(
            child: PillSegments<String>(
              options: const [('all', 'All'), ('text', 'Text'), ('links', 'Links'), ('images', 'Images')],
              value: value,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    );

TweenAnimationBuilder<Rect?> _indicator(WidgetTester t) => t
    .widgetList<TweenAnimationBuilder<Rect?>>(find.byType(TweenAnimationBuilder<Rect?>))
    .first;

double _indicatorLeft(WidgetTester t) => _indicator(t).tween.end!.left;

void main() {
  testWidgets('one indicator slides to the new choice', (t) async {
    var value = 'all';
    await t.pumpWidget(_app(value, (v) => value = v));
    await t.pump(); // measured after the first frame
    final start = _indicatorLeft(t);

    await t.tap(find.text('Images').first);
    await t.pumpWidget(_app(value, (v) => value = v));
    await t.pump();
    expect(value, 'images');
    // The ink and the on-ink label clip travel together.
    expect(find.byType(TweenAnimationBuilder<Rect?>), findsNWidgets(2));
    expect(_indicatorLeft(t), greaterThan(start));
    expect(_indicator(t).duration, ClipMotion.slide);
    expect(ClipMotion.slide.inMilliseconds, lessThan(300));
  });

  testWidgets('reduced motion: the indicator jumps, no travel', (t) async {
    var value = 'all';
    await t.pumpWidget(_app(value, (v) => value = v, reduce: true));
    await t.pump();
    await t.tap(find.text('Links').first);
    await t.pumpWidget(_app(value, (v) => value = v, reduce: true));
    await t.pump();
    expect(_indicator(t).duration, Duration.zero);
  });

  testWidgets('each pill reports its selected state', (t) async {
    await t.pumpWidget(_app('text', (_) {}));
    await t.pump();
    expect(t.getSemantics(find.text('Text').first), isSemantics(isSelected: true, isButton: true));
  });
}
